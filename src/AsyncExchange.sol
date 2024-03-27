// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IUniswapV2Factory.sol";

contract AsyncExchange {
    using Math for uint256;

    IUniswapV2Factory internal immutable _factory;

    uint256 public constant FACTOR = 10 ** 20;
    uint256 public constant FEE = 50;

    address public constant DEVELOPER_ADDRESS = 0x731591207791A93fB0Ec481186fb086E16A7d6D0;

    mapping(address => uint256) private _currentBlock;
    mapping(address => uint256) public liquidity;

    // Token1 (Deposit) -> Token2 (Withdraw) -> Total Proportion
    mapping(address => mapping(address => uint256)) public totalProportion;
    // Token1 (Deposit) -> Token2 (Withdraw) -> User Address -> Provided Proportion
    mapping(address => mapping(address => mapping(address => uint256))) public userProportion;

    constructor(address factoryAddress) {
        _factory = IUniswapV2Factory(factoryAddress);
    }

    modifier onlyOncePerBlock() {
        require(block.number != _currentBlock[tx.origin], "Async Exchange: you cannot perform this operation again in this block");
        _currentBlock[tx.origin] = block.number;
        _;
    }

    function _calculateAmountAndChargeComission(address token, uint256 amount) internal virtual returns (uint256 amountAfterComission) {
        uint256 comission = amount.mulDiv(FEE, 10_000);
        amountAfterComission = amount - (comission * 2);
        // the other part of comission stays in the contract for internal liquidity
        liquidity[token] += comission;
        IERC20(token).transfer(DEVELOPER_ADDRESS, comission);
        return amountAfterComission;
    }

    function _calculateProportion(address token0, address token1, uint256 amount) internal view virtual returns (uint256) {
        address pair = _factory.getPair(token0, token1);
        uint256 pairBalance = pair == address(0) ? liquidity[token0] : IERC20(token0).balanceOf(pair);
        return amount.mulDiv(FACTOR, pairBalance > liquidity[token0] ? pairBalance : liquidity[token0]);
    }

    function availableToWithdraw(address depositToken, address withdrawToken) public view virtual returns (uint256) {
        address pair = _factory.getPair(depositToken, withdrawToken);
        uint256 availableLiquidity = pair == address(0) ? 0 : liquidity[withdrawToken];
        return userProportion[depositToken][withdrawToken][msg.sender].mulDiv(availableLiquidity, FACTOR);
    }

    function creditToWithdraw(address depositToken, address withdrawToken) public view virtual returns (uint256) {
        address pair = _factory.getPair(depositToken, withdrawToken);
        uint256 availableLiquidity = pair == address(0) ? liquidity[withdrawToken] : IERC20(withdrawToken).balanceOf(pair);
        return userProportion[depositToken][withdrawToken][msg.sender].mulDiv(availableLiquidity, FACTOR);
    }

    function deposit(address depositToken, address withdrawToken, uint256 amount) external virtual onlyOncePerBlock {
        require(amount > 0, "Async Exchange: please deposit some amount");
        require(
            IERC20(depositToken).allowance(msg.sender, address(this)) >= amount, "Async Exchange: please approve the amount you want to deposit"
        );
        IERC20(depositToken).transferFrom(msg.sender, address(this), amount);
        liquidity[depositToken] += amount;
        uint256 proportion = _calculateProportion(depositToken, withdrawToken, amount);
        userProportion[depositToken][withdrawToken][msg.sender] += proportion;
        totalProportion[depositToken][withdrawToken] += proportion;
    }

    function withdraw(address depositToken, address withdrawToken, uint256 amount) external virtual onlyOncePerBlock {
        require(amount > 0, "Async Exchange: please inform the amount to withdraw");
        require(
            amount <= liquidity[withdrawToken] && totalProportion[withdrawToken][depositToken] > 0
                && amount <= availableToWithdraw(depositToken, withdrawToken),
            "Async Exchange: there is no available market for this pair at the moment"
        );
        require(amount <= creditToWithdraw(depositToken, withdrawToken), "Async Exchange: user does not have enough credit to withdraw");
        uint256 proportion = _calculateProportion(withdrawToken, depositToken, amount);
        liquidity[withdrawToken] -= amount;
        userProportion[depositToken][withdrawToken][msg.sender] -= proportion;
        totalProportion[withdrawToken][depositToken] -= proportion;
        IERC20(withdrawToken).transfer(msg.sender, _calculateAmountAndChargeComission(withdrawToken, amount));
    }
}

