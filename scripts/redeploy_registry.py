from brownie import accounts, AUTO, PriceOracle, Oracle, StakeManager, Registry, Forwarder, Miner
import sys
import os
sys.path.append(os.path.abspath('tests'))

from consts import *
sys.path.pop()


AUTONOMY_SEED = os.environ['AUTONOMY_SEED']
auto_accs = accounts.from_mnemonic(AUTONOMY_SEED, count=10)
DEPLOYER = auto_accs[4]

# Ropsten:
AUTO_ADDR = '0xE3e761127cBD037E18186698a2733d1e71623ebE'
# PRICE_ORACLE_ADDR = '0xEBECAe5f1249101c818FC4681adA52d097Aa3d3b'
ORACLE_ADDR = '0x3d0c9dC70c12eC0A6f5422c86E3cB4B2Bb6ABfAA'
SM_ADDR = '0x439468ED7a1ACBf5A73E5067da1B35cf8bF82Cec'
FORWARDER_ADDR = '0x16EE95Ed79141961C54411b3AB16BA787a838f25'
# REGISTRY_ADDR = '0xd839c21be3525511e76181601522c3D33B58F3b0'
# MINER_ADDR = '0x9d7c55d2f2dAA1d269BFc78d375D883750A6D50E'

def main():
    r = DEPLOYER.deploy(
        Registry,
        AUTO_ADDR,
        SM_ADDR,
        ORACLE_ADDR,
        FORWARDER_ADDR
        # publish_source=True
    )

    f = Forwarder.at(FORWARDER_ADDR)
    f.setCaller(r, True, {'from': DEPLOYER})