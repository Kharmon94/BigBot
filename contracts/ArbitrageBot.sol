pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Interfaces for Uniswap, Aave, and ERC20
interface IUniswapV2Router {
    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] memory path, address to, uint deadline) external returns (uint[] memory amounts);
}

interface IAaveLendingPool {
    function flashLoan(address receiver, address[] calldata assets, uint256[] calldata amounts, uint256[] calldata modes, address onBehalfOf, bytes calldata params, uint16 referralCode) external;
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract ArbitrageBot {
    address owner;
    bool public paused = false;
    IUniswapV2Router public uniswapRouter;
    IUniswapV2Router public sushiRouter; // Added SushiSwap router
    IAaveLendingPool public aaveLendingPool;
    uint256 public minProfit;
    uint256 public maxSlippage;
    uint256 public chunkSize;
    mapping(address => address) public tokenToOracle;

    constructor(address _uniswapRouter, address _sushiRouter, address _aaveLendingPool) {
        owner = msg.sender;
        uniswapRouter = IUniswapV2Router(_uniswapRouter);
        sushiRouter = IUniswapV2Router(_sushiRouter); // Initialize SushiSwap router
        aaveLendingPool = IAaveLendingPool(_aaveLendingPool);
        minProfit = 0.01 ether;
        maxSlippage = 50;
        chunkSize = 0.1 ether;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    function setOracleForToken(address token, address oracle) external onlyOwner {
        tokenToOracle[token] = oracle;
    }

    function getLatestPrice(address token) internal view returns (int) {
        AggregatorV3Interface oracle = AggregatorV3Interface(tokenToOracle[token]);
        (, int price,,,) = oracle.latestRoundData();
        return price;
    }

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function setMinProfit(uint256 _minProfit) external onlyOwner {
        minProfit = _minProfit;
    }

    function setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
        maxSlippage = _maxSlippage;
    }

    function setChunkSize(uint256 _chunkSize) external onlyOwner {
        chunkSize = _chunkSize;
    }

    function setApproval(address tokenAddress, address spender) external onlyOwner {
        IERC20(tokenAddress).approve(spender, type(uint256).max);
    }

    function estimateGasCost(uint256 estimatedGas) internal view returns (uint256) {
        uint256 gasPrice = tx.gasprice;
        return estimatedGas * gasPrice;
    }

    function executeOperation(address[] calldata assets, uint256[] calldata amounts, uint256[] calldata premiums, bytes calldata params) external whenNotPaused {
        address[][] memory paths = abi.decode(params, (address[][]));
        uint256 totalCost = 0;

        for(uint i = 0; i < paths.length - 1; i++) {
            uint256 estimatedGasForSwap = 200000;
            totalCost += estimateGasCost(estimatedGasForSwap);

            uint amountOutMin = uniswapRouter.getAmountsOut(amounts[i], paths[i])[paths[i].length - 1];
            uint potentialProfit = amountOutMin - amounts[i];

            uint acceptableAmountOut = amountOutMin * (10000 - maxSlippage) / 10000;

            if (IERC20(paths[i][0]).allowance(address(this), address(uniswapRouter)) < amounts[i]) {
                setApproval(paths[i][0], address(uniswapRouter));
            }

            if (potentialProfit > totalCost + minProfit && acceptableAmountOut <= amountOutMin) {
                uint chunks = amounts[i] / chunkSize;
                for (uint j = 0; j < chunks; j++) {
                    uint256 initialBalance = IERC20(paths[i][paths[i].length - 1]).balanceOf(address(this));
                    uniswapRouter.swapExactTokensForTokens(chunkSize, acceptableAmountOut * chunkSize / amounts[i], paths[i], address(this), block.timestamp + 1);
                    uint256 newBalance = IERC20(paths[i][paths[i].length - 1]).balanceOf(address(this));
                    require(newBalance > initialBalance, "Trade failed or was not profitable");
                }
            }
        }

        for(uint i = 0; i < assets.length; i++) {
            IERC20(assets[i]).approve(address(aaveLendingPool), amounts[i] + premiums[i]);
        }
    }

    function startArbitrage(address[] calldata assets, uint256[] calldata amounts, address[][] calldata paths) external onlyOwner whenNotPaused {
        bytes memory data = abi.encode(paths);
        aaveLendingPool.flashLoan(address(this), assets, amounts, new uint256[](assets.length), address(this), data, 0);
    }
}
