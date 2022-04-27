// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "ds-test/test.sol";

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {UniswapV2Pair} from "./utils/uniswap-v2/UniswapV2Pair.sol";
import {UniswapV2Factory} from "./utils/uniswap-v2/UniswapV2Factory.sol";
import {IUniswapV2Pair} from "../contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "../contracts/interfaces/IUniswapV2Factory.sol";
import {PairInfo} from "../contracts/interfaces/IPriceOracle.sol";
import {WETH} from "../contracts/mocks/WETH.sol";
import {MockERC20Upgradeable} from "../contracts/mocks/ERC20.sol";
import {console, CheatCodes, SetupEnvironment, User, Curator, UserNoETH, Pair, PairWithWETH} from "./utils/utils.sol"; 
import "../contracts/libraries/math/FixedPoint.sol";
import "../contracts/libraries/UQ112x112.sol";


contract PriceOracleTest is DSTest {
    using FixedPoint for *;
    using UQ112x112 for uint224;

    CheatCodes public vm;
    
    WETH public weth;
    PriceOracle public priceOracle;
    IUniswapV2Factory public factory;
    Pair public pair;
    PairWithWETH public pairWithWeth;
    
    function setUp() public {
        (vm, weth, factory, priceOracle, , , ) = SetupEnvironment.setup(10 ether, 1000 ether);        
        MockERC20Upgradeable token0 = new MockERC20Upgradeable();
        token0.initialize("Fake Token 0", "FT0");
        token0.mint(address(this), 100 ether);

        MockERC20Upgradeable token1 = new MockERC20Upgradeable(); 
        token1.initialize("Fake Token 1", "FT1");
        token1.mint(address(this), 100 ether);
        
        pair = new Pair(address(factory), address(token0), address(token1), vm);
        pair.receiveToken(50 ether, 100 ether);
        
        pairWithWeth = new PairWithWETH(address(factory), address(token0), address(weth), vm);
        pairWithWeth.receiveToken(50 ether, 100 ether);

        priceOracle = new PriceOracle(address(factory), address(weth));
    }

    /**
    Test internal method addPairInfo which gets called during updatePairInfo if the pair info doesn't exist in price oracle.
     */
    function testAddPairInfo() public {
        // ACTION
        // Add pair info to price oracle for token0 and token1.
        address token0 = address(pair.token0());
        address token1 = address(pair.token1());
        address pairAddress = address(pair.uPair());
        priceOracle.updatePairInfo(token0, token1);

        // VERIFY
        // Get pair info with pair address.
        PairInfo memory pairInfo = priceOracle.getPairInfo(token0, token1);
        (, , uint32 blockTimestamp) = IUniswapV2Pair(pairAddress).getReserves();

        // Get token addresses with UniswapV2Pair interface.
        address tokenA = IUniswapV2Pair(pairAddress).token0();
        address tokenB = IUniswapV2Pair(pairAddress).token1();
        
        assertEq(pairInfo.token0, tokenA);
        assertEq(pairInfo.token1, tokenB);
        assertEq(pairInfo.price0CumulativeLast, 0);
        assertEq(pairInfo.price1CumulativeLast, 0);
        assertEq(pairInfo.price0Average._x, uint224(0));
        assertEq(pairInfo.price1Average._x, uint224(0));
        assertEq(pairInfo.totalUpdates, 0);
        assertEq(pairInfo.blockTimestampLast, blockTimestamp);
        assertTrue(pairInfo.exists);
    }

    /**
    Test updatePairInfo which gets called when the pair info exists in price oracle.
     */
    function testUpdatePairInfo() public {
        // ACTION
        // Add pair info to price oracle.
        address pairAddress = address(pair.uPair());
        address token0 = address(pair.token0());
        address token1 = address(pair.token1());
        // Since pair info does not exist in price oracle, updatePairInfo would add pair info to price oracle.
        priceOracle.updatePairInfo(token0, token1); 
        (, , uint256 t0) = IUniswapV2Pair(pairAddress).getReserves();

        // Get the last blocktimestamp and move block.timestamp forward.
        uint jump = priceOracle.period();
        vm.warp(t0 + jump);
        IUniswapV2Pair(pairAddress).sync();

        // Update price oracle. 
        priceOracle.updatePairInfo(token0, token1);

        // VERIFY 
        // check that price has been updated in price oracle.
        PairInfo memory pairInfo = priceOracle.getPairInfo(token0, token1);
        
        // price(0|1)CumulativeLast = 0 * t0 + token(0|1)Balance * t1
        uint112 token0Balance = uint112(IERC20Upgradeable(token0).balanceOf(pairAddress));
        uint112 token1Balance = uint112(IERC20Upgradeable(token1).balanceOf(pairAddress));
        assertEq(pairInfo.price0CumulativeLast, uint256(UQ112x112.encode(token1Balance).uqdiv(token0Balance)) * jump);
        assertEq(pairInfo.price1CumulativeLast, uint256(UQ112x112.encode(token0Balance).uqdiv(token1Balance)) * jump);

        // price(0|1)Average = (0 * t0 + token(0|1)Balance * t1) / period
        assertEq(pairInfo.price0Average._x, uint256(UQ112x112.encode(token1Balance).uqdiv(token0Balance))); 
        assertEq(pairInfo.price1Average._x, uint256(UQ112x112.encode(token0Balance).uqdiv(token1Balance)));
    }
   
    /**
    Test updatePairInfo when uniswap pair does not exist.
     */
    function testUpdatePairInfo_pairDoesNotExist() public {
        // ACTION
        // Update pair info with tokens which uniswap pair does not exist.
        address token0 = address(new MockERC20Upgradeable());
        address token1 = address(new MockERC20Upgradeable());
        priceOracle.updatePairInfo(token0, token1);
        
        // VERIFY
        // Check that the pair is not updated and does not exist in price oracle.
        PairInfo memory pairInfo = priceOracle.getPairInfo(token0, token1);
        assertTrue(!pairInfo.exists);
    }
    
    /**
    Test updatePairInfo when period has not elapsed. 
     */
    function testUpdatePairInfo_periodNotElapsed() public {
        // ACTION
        // Add pair info to price oracle.
        address pairAddress = address(pair.uPair());
        address token0 = address(pair.token0());
        address token1 = address(pair.token1());
        priceOracle.updatePairInfo(token0, token1);

        // Sync pair to match reserve to token balances. 
        IUniswapV2Pair(pairAddress).sync();
        (, , uint256 t0) = IUniswapV2Pair(pairAddress).getReserves();

        // Get the last blocktimestamp and move block.timestamp forward but shorter than required update period.
        uint jump = priceOracle.period() - 1 minutes;
        vm.warp(t0 + jump);
        IUniswapV2Pair(pairAddress).sync();

        // Update price oracle. 
        priceOracle.updatePairInfo(token0, token1);

        // VERIFY 
        // check that price has NOT been updated in price oracle.
        PairInfo memory pairInfo = priceOracle.getPairInfo(token0, token1);
        
        // price(0|1)CumulativeLast = 0 * t0 + token(0|1)Balance * t1
        uint112 token0Balance = uint112(IERC20Upgradeable(token0).balanceOf(pairAddress));
        uint112 token1Balance = uint112(IERC20Upgradeable(token1).balanceOf(pairAddress));
        assertTrue(pairInfo.price0CumulativeLast != uint256(UQ112x112.encode(token1Balance).uqdiv(token0Balance)) * jump);
        assertTrue(pairInfo.price1CumulativeLast != uint256(UQ112x112.encode(token0Balance).uqdiv(token1Balance)) * jump);

        // price(0|1)Average = (0 * t0 + token(0|1)Balance * t1) / period
        assertTrue(pairInfo.price0Average._x != uint256(UQ112x112.encode(token1Balance).uqdiv(token0Balance))); 
        assertTrue(pairInfo.price1Average._x != uint256(UQ112x112.encode(token1Balance).uqdiv(token0Balance)));
    }
    
    /**
    Test retrieving token(fNFT) price in ETH.
     */
    function testfNFTPriceETH() public {
        // ACTION
        // Add pair info to price oracle.
        address pairAddress = address(pairWithWeth.uPair());
        address fNFT = address(pairWithWeth.token());
        address wethToken = address(weth);
        priceOracle.updatePairInfo(fNFT, wethToken);
        IUniswapV2Pair(pairAddress).sync();
        (, , uint256 blockTimeStampLast) = IUniswapV2Pair(pairAddress).getReserves();

        // Move block.timestamp forward and sync uniswap pair and update price oracle.
        // Update price oracle pair 10 times to meet the requirement.
        uint jump = priceOracle.period();
        for (uint i = 0; i <= priceOracle.minimumPairInfoUpdate(); i++) {
            blockTimeStampLast += jump;
            vm.warp(blockTimeStampLast);
            IUniswapV2Pair(pairAddress).sync();
            priceOracle.updatePairInfo(fNFT, wethToken);
        }

        // Get Price of FNFT in ETH.
        uint fNFTAmount = 50 ether;
        uint ethPrice = priceOracle.getfNFTPriceETH(fNFT, fNFTAmount);
        
        // VERIFY
        assertEq(ethPrice, fNFTAmount * weth.balanceOf(pairAddress)/IERC20Upgradeable(fNFT).balanceOf(pairAddress));
    }

    /**
    Test failure in retrieving token(fNFT) price in ETH when not enough updates to pair's twap.
     */
    function testFail_fNFTPriceETH_notEnoughUpdates() public {
        // ACTION
        // Add pair info to price oracle.
        address pairAddress = address(pairWithWeth.uPair());
        address fNFT = address(pairWithWeth.token());
        address wethToken = address(weth);
        priceOracle.updatePairInfo(fNFT, wethToken);
        IUniswapV2Pair(pairAddress).sync();
        (, , uint256 blockTimeStampLast) = IUniswapV2Pair(pairAddress).getReserves();

        // Move block.timestamp forward and sync uniswap pair and update price oracle.
        // Update price oracle pair less than required pair info update.
        uint jump = priceOracle.period();
        for (uint i = 0; i <= priceOracle.minimumPairInfoUpdate() - 3; i++) {
            blockTimeStampLast += jump;
            vm.warp(blockTimeStampLast);
            IUniswapV2Pair(pairAddress).sync();
            priceOracle.updatePairInfo(fNFT, wethToken);
        }

        // Get Price of FNFT in ETH.
        priceOracle.getfNFTPriceETH(fNFT, 50 ether);
    }
    
    /**
    Test failure in retrieving token(fNFT) price in ETH when twap does not exist.
     */
    function testFail_fNFTPriceETH_pairInfoDoesNotExist() public {
        // ACTION
        // Add pair info to price oracle.
        address pairAddress = address(pairWithWeth.uPair());
        address fNFT = address(pairWithWeth.token());
        address wethToken = address(weth);
        address fakeToken = address(new MockERC20Upgradeable());
        priceOracle.updatePairInfo(fNFT, wethToken);
        IUniswapV2Pair(pairAddress).sync();
        (, , uint256 blockTimeStampLast) = IUniswapV2Pair(pairAddress).getReserves();

        // Move block.timestamp forward and sync uniswap pair and update price oracle.
        // Update price oracle pair less than required pair info update.
        uint jump = priceOracle.period();
        for (uint i = 0; i <= priceOracle.minimumPairInfoUpdate(); i++) {
            blockTimeStampLast += jump;
            vm.warp(blockTimeStampLast);
            IUniswapV2Pair(pairAddress).sync();
            priceOracle.updatePairInfo(fNFT, wethToken);
        }

        // Get Price of fakeToken in ETH.
        priceOracle.getfNFTPriceETH(fakeToken, 50 ether);
    }
}
