# 🛡️ AEGIS-V3 Sentinel

[![Drosera Network](https://img.shields.io/badge/Drosera-Network-6C47FF?style=for-the-badge&logo=ethereum&logoColor=white)](https://drosera.io)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.33-363636?style=for-the-badge&logo=solidity&logoColor=white)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF6B35?style=for-the-badge)](https://getfoundry.sh)
[![Network](https://img.shields.io/badge/Network-Hoodi%20Testnet-0052FF?style=for-the-badge)](https://hoodi.etherscan.io)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

> **Lido V3 VaultHub Risk Sentinel** — Real-time on-chain monitoring for Lido V3 stVaults ecosystem, powered by [Drosera Network](https://drosera.io).

---

## 📌 Overview

AEGIS-V3 is a production-grade [Drosera trap](https://docs.drosera.io) that continuously monitors the **Lido V3 VaultHub** smart contract for systemic risk signals. It samples vault health, tracks bad debt accumulation, detects protocol pauses, and monitors wstETH redemption rate degradation — all in a single, gas-optimized trap execution.

Built for the Drosera Network's decentralized security layer, AEGIS-V3 enables automated incident response the moment on-chain conditions deteriorate.

---

## ⚡ Live Deployment (Hoodi Testnet)

| Contract | Address | Explorer |
|---|---|---|
| **AegisV3Sentinel** (Trap) | `0x047aEdd2215C6E22E1a8128A9A98735FfF666aff` | [View ↗](https://hoodi.etherscan.io/address/0x047aEdd2215C6E22E1a8128A9A98735FfF666aff) |
| **AegisV3Response** | `0x6A389da253A1D4B0fA5f5b0fe6843164398e9f45` | [View ↗](https://hoodi.etherscan.io/address/0x6A389da253A1D4B0fA5f5b0fe6843164398e9f45) |
| **VaultHub** (Monitored) | `0x4C9fFC325392090F789255b9948Ab1659b797964` | [View ↗](https://hoodi.etherscan.io/address/0x4C9fFC325392090F789255b9948Ab1659b797964) |
| **stETH** (Monitored) | `0x3508A952176b3c15387C97BE809eaffB1982176a` | [View ↗](https://hoodi.etherscan.io/address/0x3508A952176b3c15387C97BE809eaffB1982176a) |
| **wstETH** (Monitored) | `0x7E99eE3C66636DE415D2d7C880938F2f40f94De4` | [View ↗](https://hoodi.etherscan.io/address/0x7E99eE3C66636DE415D2d7C880938F2f40f94De4) |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Drosera Network                          │
│  ┌─────────────┐    attestation    ┌──────────────────────┐ │
│  │  Operators  │◄─────────────────►│   Drosera Protocol   │ │
│  └──────┬──────┘                   └──────────────────────┘ │
│         │ execute every block                               │
└─────────┼───────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│               AegisV3Sentinel (Trap)                        │
│                                                             │
│  collect()          shouldRespond()      shouldAlert()      │
│  ┌──────────────┐   ┌──────────────┐    ┌──────────────┐   │
│  │ Read on-chain│   │ Check A: Bad │    │ Future:      │   │
│  │ state from:  │──►│ Debt > 0     │    │ Alert system │   │
│  │ • VaultHub   │   │ Check B: Is  │    └──────────────┘   │
│  │ • stETH      │   │ Paused?      │                       │
│  │ • wstETH     │   │ Check C: 20% │                       │
│  │ • 10 Vaults  │   │ Unhealthy    │                       │
│  └──────────────┘   │ Check D: Rate│                       │
│                     │ Drop >300bps │                       │
│                     └──────┬───────┘                       │
└────────────────────────────┼────────────────────────────────┘
                             │ should_respond = true
                             ▼
┌─────────────────────────────────────────────────────────────┐
│               AegisV3Response (Response Contract)           │
│                                                             │
│  recordBadDebt()              → CRITICAL severity           │
│  recordProtocolPause()        → CRITICAL severity           │
│  recordVaultHealthDegradation() → HIGH severity             │
│  recordRedemptionRateDrop()   → HIGH severity               │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔍 How It Works

### Data Collection (`collect()`)

Every block, the sentinel reads a comprehensive snapshot of the Lido V3 ecosystem:

```solidity
struct AegisSnapshot {
    uint256 vaultsCount;          // Total stVaults registered
    uint256 badDebt;              // Bad debt pending internalization
    bool    protocolPaused;       // VaultHub pause state
    uint256 unhealthyVaults;      // Unhealthy vaults in 10-vault sample
    uint256 totalShortfallShares; // Aggregate shortfall across sample
    uint256 wstEthRate;           // Current wstETH/stETH exchange rate
    uint256 totalPooledEther;     // Total ETH pooled in stETH protocol
    uint256 shareRatioBps;        // Rate expressed in basis points
    bool    valid;                // Snapshot validity flag
}
```

### Risk Detection (`shouldRespond()`)

Four independent risk checks run on every snapshot:

| Check | Signal | Threshold | Severity |
|---|---|---|---|
| **A — Bad Debt** | `badDebtToInternalize() > 0` | Any bad debt | 🔴 CRITICAL |
| **B — Protocol Pause** | `isPaused()` state change | `false → true` | 🔴 CRITICAL |
| **C — Vault Health** | Unhealthy vaults in sample | ≥ 2 of 10 (20%) | 🟠 HIGH |
| **D — Rate Degradation** | wstETH/stETH rate drop | > 300 bps sustained | 🟠 HIGH |

### Response Mapping

Each check triggers a specific response function with relevant on-chain data:

```
Check A → recordBadDebt(vaultsCount, badDebt, timestamp)
Check B → recordProtocolPause(vaultsCount, timestamp)
Check C → recordVaultHealthDegradation(vaultsCount, unhealthyVaults, totalShortfallShares)
Check D → recordRedemptionRateDrop(vaultsCount, wstEthRate, shareRatioBps)
```

---

## 📊 Performance Stats

From live dryrun on Hoodi testnet (block `2408084`):

| Metric | Value |
|---|---|
| `collect()` gas used | 385,516 |
| `shouldRespond()` gas used | 58,800 |
| Accounts queried | 8 |
| Storage slots queried | 65 |
| Bootstrap duration | ~13s |
| Runtime duration | ~625ms |

---

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh) installed
- [Drosera CLI](https://docs.drosera.io) installed
- Hoodi testnet ETH (faucet: [hoodi.ethpandaops.io](https://hoodi.ethpandaops.io))

### Installation

```bash
git clone https://github.com/DAOmindbreaker/aegis-v3-sentinel.git
cd aegis-v3-sentinel
forge install
forge build
```

### Run Dryrun

```bash
drosera dryrun
```

Expected output:
```
should_respond: false   ← normal when protocol is healthy
collect() gas used: 385,516
shouldRespond() gas used: 58,800
accounts queried: 8
slots queried: 65
```

### Deploy Response Contract

```bash
export PRIVATE_KEY=0xYOUR_PRIVATE_KEY

forge create src/AegisV3Response.sol:AegisV3Response \
  --rpc-url https://ethereum-hoodi-rpc.publicnode.com \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args YOUR_OPERATOR_ADDRESS
```

### Configure & Apply Trap

Update `drosera.toml` with your deployed response contract address, then:

```bash
export DROSERA_PRIVATE_KEY=$PRIVATE_KEY
drosera apply
```

---

## 📁 Project Structure

```
aegis-v3-sentinel/
├── src/
│   ├── AegisV3Sentinel.sol     # Main trap — data collection & risk detection
│   └── AegisV3Response.sol     # Response contract — on-chain incident logging
├── test/
│   └── (tests coming soon)
├── drosera.toml                # Trap configuration
├── foundry.toml                # Foundry configuration
└── README.md
```

---

## 🤝 Contributing

Contributions are welcome! Here's how to get started:

1. **Fork** this repository
2. **Create** a feature branch: `git checkout -b feat/your-feature`
3. **Build** and verify: `forge build` (must be zero warnings)
4. **Dryrun** your changes: `drosera dryrun`
5. **Commit** with clear message: `git commit -m "feat: describe your change"`
6. **Open a Pull Request** with description of what was changed and why

### Ideas for Contributions

- [ ] Add `shouldAlert()` implementation for off-chain alerting
- [ ] Expand vault sampling beyond 10 vaults (adaptive sampling)
- [ ] Add Aave V3 integration for cross-protocol risk correlation
- [ ] Add Uniswap V3 wstETH/ETH pool monitoring
- [ ] Write comprehensive Foundry tests
- [ ] Mainnet deployment configuration

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.

---

## 🔗 Resources

- [Drosera Network Docs](https://docs.drosera.io)
- [Lido V3 Documentation](https://docs.lido.fi)
- [VaultHub on Hoodi Explorer](https://hoodi.etherscan.io/address/0x4C9fFC325392090F789255b9948Ab1659b797964)
- [Foundry Book](https://book.getfoundry.sh)

---

<p align="center">Built with ❤️ for the Drosera Network ecosystem</p>
