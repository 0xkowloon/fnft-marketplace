import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {deployments, getNamedAccounts, ethers} = hre;
  
  const {deploy, get} = deployments;
  const {deployer} = await getNamedAccounts();

  const signer = await ethers.getSigner(deployer);

  // get fnft settings proxy address
  const proxyControllerInfo = await get('MultiProxyController');
  const proxyController = new ethers.Contract(
    proxyControllerInfo.address,
    proxyControllerInfo.abi,
    signer
  );
  const fnftSettingsAddress = (await proxyController.proxyMap(
    ethers.utils.formatBytes32String("FNFTSettings")
  ))[1];  

  // deploy implementation contract
  const fnftFactoryImpl = await deploy('FNFTFactory', {
    from: deployer,
    log: true,
  });

  // deploy proxy contract
  const deployerInfo = await get('Deployer')
  const deployerContract = new ethers.Contract(
    deployerInfo.address,
    deployerInfo.abi,
    signer
  );
  await deployerContract.deployFNFTFactory(
    fnftFactoryImpl.address, 
    fnftSettingsAddress
  );

};

func.tags = ['main', 'local', 'seed'];
export default func;