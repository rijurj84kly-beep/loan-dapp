// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./MockPriceOracle.sol";

contract LendingPool is ReentrancyGuard {
    IERC20 public collateralToken;
    IERC20 public borrowToken;
    MockPriceOracle public priceOracle;

    // LTV (Loan to Value) ratio: e.g., 75% means you can borrow up to 75% of collateral value
    uint256 public constant LTV_PERCENTAGE = 75; 
    uint256 public constant LIQUIDATION_THRESHOLD = 80; // If debt > 80% of collateral value, liquidatable
    uint256 public constant LIQUIDATION_BONUS = 5; // Liquidator gets 5% bonus collateral

    struct UserAccount {
        uint256 collateralBalance;
        uint256 borrowedAmount;
    }

    mapping(address => UserAccount) public accounts;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtCovered, uint256 collateralLiquidated);

    constructor(address _collateralToken, address _borrowToken, address _priceOracle) {
        collateralToken = IERC20(_collateralToken);
        borrowToken = IERC20(_borrowToken);
        priceOracle = MockPriceOracle(_priceOracle);
    }

    // 1. Deposit Collateral
    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        accounts[msg.sender].collateralBalance += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    // 2. Withdraw Collateral
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(accounts[msg.sender].collateralBalance >= amount, "Insufficient collateral");

        // Optimistically update balance
        accounts[msg.sender].collateralBalance -= amount;

        // Check health factor after withdrawal
        require(_getHealthFactor(msg.sender) >= 1e18, "Health factor too low");

        require(collateralToken.transfer(msg.sender, amount), "Transfer failed");
        emit CollateralWithdrawn(msg.sender, amount);
    }

    // 3. Borrow
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        accounts[msg.sender].borrowedAmount += amount;

        // Check if collateral supports the borrow
        require(_getHealthFactor(msg.sender) >= 1e18, "Insufficient collateral for borrow");

        require(borrowToken.transfer(msg.sender, amount), "Transfer failed");
        emit Borrowed(msg.sender, amount);
    }

    // 4. Repay
    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        uint256 debt = accounts[msg.sender].borrowedAmount;
        uint256 amountToRepay = amount > debt ? debt : amount;

        accounts[msg.sender].borrowedAmount -= amountToRepay;

        require(borrowToken.transferFrom(msg.sender, address(this), amountToRepay), "Transfer failed");
        emit Repaid(msg.sender, amountToRepay);
    }

    // 5. Liquidate
    function liquidate(address user, uint256 debtToCover) external nonReentrant {
        require(_getHealthFactor(user) < 1e18, "User health factor is good");
        
        uint256 userDebt = accounts[user].borrowedAmount;
        require(debtToCover <= userDebt, "Cannot cover more than user debt");

        // Calculate collateral to give to liquidator including bonus
        // collateralAmount = (debtToCover * borrowPrice) / collateralPrice
        uint256 collateralPrice = priceOracle.getPrice(address(collateralToken));
        uint256 borrowPrice = priceOracle.getPrice(address(borrowToken));
        
        uint256 collateralNeeded = (debtToCover * borrowPrice) / collateralPrice;
        uint256 collateralWithBonus = collateralNeeded + ((collateralNeeded * LIQUIDATION_BONUS) / 100);

        require(accounts[user].collateralBalance >= collateralWithBonus, "Not enough collateral to liquidate");

        // Update balances
        accounts[user].collateralBalance -= collateralWithBonus;
        accounts[user].borrowedAmount -= debtToCover;

        // Transfer borrow token from liquidator to pool
        require(borrowToken.transferFrom(msg.sender, address(this), debtToCover), "Transfer failed");
        
        // Transfer collateral to liquidator
        require(collateralToken.transfer(msg.sender, collateralWithBonus), "Transfer failed");

        emit Liquidated(user, msg.sender, debtToCover, collateralWithBonus);
    }

    // --- View Functions & Internal Logic ---

    function getAccountInfo(address user) external view returns (uint256 collateral, uint256 debt, uint256 healthFactor) {
        return (accounts[user].collateralBalance, accounts[user].borrowedAmount, _getHealthFactor(user));
    }

    function _getHealthFactor(address user) internal view returns (uint256) {
        uint256 collateralBalance = accounts[user].collateralBalance;
        uint256 borrowedAmount = accounts[user].borrowedAmount;

        if (borrowedAmount == 0) return type(uint256).max; // Infinite health

        uint256 collateralPrice = priceOracle.getPrice(address(collateralToken));
        uint256 borrowPrice = priceOracle.getPrice(address(borrowToken));

        uint256 collateralValue = collateralBalance * collateralPrice;
        uint256 borrowedValue = borrowedAmount * borrowPrice;

        // Liquidation Threshold determines the real max borrowing capacity before liquidation
        uint256 collateralValueWithThreshold = (collateralValue * LIQUIDATION_THRESHOLD) / 100;

        // Health Factor = (Collateral Value * Threshold) / Borrowed Value
        // >= 1e18 means good. < 1e18 means liquidatable.
        return (collateralValueWithThreshold * 1e18) / borrowedValue;
    }
}
