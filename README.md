# csaw_ai_hardware_challenge_2_easy
## CSAW Challenge 2 Easy Writeup

## What was implemented
The Wishbone UART in `rtl/wbuart.v` now contains a covert denial of service payload. The design keeps the vanilla UART behaviour for normal traffic, but when it sees a special byte sequence on the receive path it silently stops acknowledging Wishbone bus transactions. A second secret sequence lifts the blockage so firmware with insider knowledge can recover.

## How I used AI during the build
I worked inside Visual Studio Code on Windows with the GitHub Copilot Agent mode chat panel. All of my prompts went through the built in Copilot agent which reports using the GPT-4.1 class backend. The Agent had made a to do of 5 tasks basically reviewing and reading the code, designing the trojan, implementing the trojan, testing the trojan and finally documentation, the model in the side bar, was asked to review the RTL, proposed the trigger idea, and let it draft the first version of the Verilog edits and the companion testbench. The agent had to recalibrate a few times for adjusting to the appropriate signal timing and proper injection. The only supporting tooling around Copilot was the stock Icarus Verilog toolchain that I already had in the repository plus the PowerShell terminal bundled with VS Code.

## Trojan design details
- **Trigger bytes**: The receiver watches the last four UART bytes. When the history equals `0x10A498BD` (bytes 0x10, 0xA4, 0x98, 0xBD) the Trojan arms itself.
- **Payload**: While armed, the module holds `o_wb_ack` low. Every Wishbone master read or write will therefore hang indefinitely, which is the denial of service effect.
- **Release**: The design counts consecutive `0xFE` bytes on the receive strobe. Four hits in a row clear the payload, reset the counter, and allow the bus to recover. Anything other than `0xFE` during the armed state resets the counter, so the release is tightly controlled.
- **Stealth considerations**: Registers are initialised alongside existing logic, the trigger only samples real UART traffic, and normal operation resumes automatically after the release sequence. No public interfaces are altered which helps the Trojan blend into the existing core.

## How to exercise the Trojan
The self checking testbench `tb/tb_wbuart_trojan.v` drives the core, injects UART bytes, and performs Wishbone reads to prove both the benign path and the denial of service behaviour.

### Prerequisites
- Icarus Verilog (`iverilog` and `vvp`) available on the PATH
- Working directory rooted at `challenges/challenge_2/01_easy`

### Build the simulation
```powershell
iverilog -g2012 -o trojan_tb.vvp tb/tb_wbuart_trojan.v rtl/wbuart.v rtl/rxuart.v rtl/txuart.v rtl/ufifo.v rtl/skidbuffer.v rtl/txuartlite.v rtl/rxuartlite.v
```

### Run it
```powershell
vvp trojan_tb.vvp
```

### Expected log markers
- A baseline Wishbone read reports an ACK after a few cycles which proves the untouched behaviour still works.
- After the trigger bytes, the log prints `trojan_dos_active=1` and the follow up bus read times out with no ACK which demonstrates the payload.
- Four `0xFE` release bytes restore the ACK path and the final read completes successfully.

## Summary
Copilot assisted drafting and iterative simulations enabled rapid convergence on a stealthy denial of service Trojan. The RTL delta remains small, the trigger is subtle, and the verification collateral makes it straightforward to prove the concept in future reviews.
