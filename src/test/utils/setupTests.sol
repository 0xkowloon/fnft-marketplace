// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "../../../lib/ds-test/src/test.sol";
import {Deployer} from "../../contracts/proxy/Deployer.sol";
import {MultiProxyController} from "../../contracts/proxy/MultiProxyController.sol";
import {CheatCodes} from "./cheatcodes.sol";
import {console} from "./console.sol";
import {WETH} from "../../contracts/mocks/WETH.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {IFOSettings} from "../../contracts/IFOSettings.sol";
import {IFOFactory} from "../../contracts/IFOFactory.sol";
import {FNFTSettings} from "../../contracts/FNFTSettings.sol";
import {FNFTFactory} from "../../contracts/FNFTFactory.sol";
import {IUniswapV2Factory} from "../../contracts/interfaces/IUniswapV2Factory.sol";
import {IFNFT} from "../../contracts/interfaces/IFNFT.sol";
import {FNFTFactory} from "../../contracts/FNFTFactory.sol";
import {FNFT} from "../../contracts/FNFT.sol";
import {MockNFT} from "../../contracts/mocks/NFT.sol";

contract SetupEnvironment {
    Deployer public deployer;
    CheatCodes public vm;
    MultiProxyController public proxyController;
    WETH public weth;

    function setupDeployerAndProxyController() public {
        deployer = new Deployer();
        bytes32[] memory keys;
        address[] memory proxies;
        proxyController = new MultiProxyController(keys, proxies, address(deployer));
        deployer.setProxyController(address(proxyController));
    }

    function setupWETH(uint256 _amountToMint) public {
        weth = new WETH(_amountToMint);
    }

    function setupPairFactory() public pure returns (IUniswapV2Factory v2Factory) {
        v2Factory = IUniswapV2Factory(0xc66F594268041dB60507F00703b152492fb176E7);
    }

    function setupPriceOracle(address v2Factory) public returns (PriceOracle priceOracle) {        
        priceOracle = PriceOracle(
            deployer.deployPriceOracle(address(new PriceOracle(v2Factory, address(weth))))
        );                
    }

    function setupIFOSettings() public returns (IFOSettings ifoSettings) {
        ifoSettings = IFOSettings(
            deployer.deployIFOSettings(address(new IFOSettings()))
        );
    }

    function setupIFOFactory(address _ifoSettings) public returns (IFOFactory ifoFactory) {
        ifoFactory = IFOFactory(
            deployer.deployIFOFactory(address(new IFOFactory()), _ifoSettings)
        );
    }

    function setupFNFTSettings(address _ifoFactory, address _priceOracle) public returns (FNFTSettings fnftSettings) {        
        fnftSettings = FNFTSettings(
            deployer.deployFNFTSettings(address(new FNFTSettings()), address(weth), _ifoFactory)
        );
        fnftSettings.setPriceOracle(_priceOracle);
    }

    function setupFNFTFactory(address _fnftSettings) public returns (FNFTFactory fnftFactory) {        
        fnftFactory = FNFTFactory(
            deployer.deployFNFTFactory(address(new FNFTFactory()), address(_fnftSettings))
        );
    }

    function setupFNFT(address _fnftFactory, uint256 _amountToMint) public returns (FNFT fnft) {
        FNFTFactory factory = FNFTFactory(_fnftFactory);

        MockNFT token = new MockNFT();

        token.mint(address(this), 1);

        token.setApprovalForAll(_fnftFactory, true);
        
        // FNFT minted on this test contract address.
        fnft = FNFT(factory.mint("testName", "TEST", address(token), 1, _amountToMint, 1 ether, 50));
    }
   
    function setupEnvironment(uint256 _wethAmount) public {
        vm = CheatCodes(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));        
        setupDeployerAndProxyController();        
        setupWETH(_wethAmount);           
    }

    function setupContracts(uint256 _fnftAmount)
        public
        returns (
            IUniswapV2Factory pairFactory,
            PriceOracle priceOracle,
            IFOSettings ifoSettings,
            IFOFactory ifoFactory,
            FNFTSettings fnftSettings,
            FNFTFactory fnftFactory,
            FNFT fnft
        )
    {             
        pairFactory = setupPairFactory();        
        priceOracle = setupPriceOracle(address(pairFactory));        
        ifoSettings = setupIFOSettings();
        ifoFactory = setupIFOFactory(address(ifoSettings));
        fnftSettings = setupFNFTSettings(address(ifoFactory), address(priceOracle));
        fnftFactory = setupFNFTFactory(address(fnftSettings));
        fnft = setupFNFT(address(fnftFactory), _fnftAmount);        
    }
}
