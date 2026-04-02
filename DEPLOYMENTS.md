# Deployments

## Sepolia (Chain ID: 11155111)

**Deployed:** 2026-03-31  
**Deployer:** `0x1C8236B406911A376369e33D39189F1b4B39F27D`  
**Block:** `0xa11cbb` (10559675)  
**Commit:** `781fc26`

| Contract             | Address                                      | Type           |
| -------------------- | -------------------------------------------- | -------------- |
| Snaxpot (proxy)      | `0x82A316550d8dc75cE3900dc04edea9E92190d06F` | ERC1967 (UUPS) |
| Snaxpot (impl)       | `0x93cF824a82930F9a640abb25164bb74237343134` | Implementation |
| JackpotClaimer       | `0xB9bb92D7023903051A7c0eC78cc5d720a6c352fA` | CREATE2        |
| PrizeDistributor     | `0x8c9329F45C39b5e14658f117D9f3ae437Be5Fe33` |                |
| MockUSDT             | `0x681Fe53aDf91c15E045e3715e3F1800E12642d6D` | Mock ERC-20    |

**Roles**

| Role           | Address                                      |
| -------------- | -------------------------------------------- |
| Admin          | `0x1C8236B406911A376369e33D39189F1b4B39F27D` |
| Operator       | `0x1C8236B406911A376369e33D39189F1b4B39F27D` |

**External Dependencies**

| Dependency       | Address                                      |
| ---------------- | -------------------------------------------- |
| Deposit Contract | `0x5Ed4a299E9fa36E6bDb4E0723bD3ad9D233f33A0` |

### VRF (Chainlink V2.5)

| Parameter              | Value                                                                |
| ---------------------- | -------------------------------------------------------------------- |
| Coordinator            | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B`                        |
| Subscription ID        | `0xe95d60d9a1aa0bff28292afc848dd3a2c8af5fd89a0368e3da5f86af67beb731` |
| Key Hash (500 gwei)    | `0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae` |
| Callback Gas Limit     | 500,000                                                              |
| Request Confirmations  | 6                                                                    |
| Payment                | LINK (native = false)                                                |

**Subscription dashboard:** https://vrf.chain.link/sepolia/0xe95d60d9a1aa0bff28292afc848dd3a2c8af5fd89a0368e3da5f86af67beb731

---

## Ethereum Mainnet (Chain ID: 1)

> **Status:** Not yet deployed

| Contract             | Address | Type           |
| -------------------- | ------- | -------------- |
| Snaxpot (proxy)      | TBD     | ERC1967 (UUPS) |
| Snaxpot (impl)       | TBD     | Implementation |
| JackpotClaimer       | TBD     | CREATE2        |
| PrizeDistributor     | TBD     |                |
| USDT                 | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | Tether USD     |

**Roles**

| Role           | Address |
| -------------- | ------- |
| Admin          | TBD     |
| Operator       | TBD     |

**External Dependencies**

| Dependency       | Address |
| ---------------- | ------- |
| Deposit Contract | TBD     |

### VRF (Chainlink V2.5)

| Parameter              | Value                                                                |
| ---------------------- | -------------------------------------------------------------------- |
| Coordinator            | `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`                        |
| Subscription ID        | `5330192387165040450955724409606646435630154022463086287525624162744670700267` |
| Key Hash (500 gwei)    | `0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b` |
| Callback Gas Limit     | 500,000                                                              |
| Request Confirmations  | 6                                                                    |
| Payment                | LINK (native = false)                                                |

**Subscription dashboard:** https://vrf.chain.link/ethereum/5330192387165040450955724409606646435630154022463086287525624162744670700267
