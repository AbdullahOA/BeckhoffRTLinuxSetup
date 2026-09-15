Beckhoff RT Linux Setup  -  unofficial tool by Abdullah Omar, Beckhoff UAE
(not an official or supported Beckhoff product - use at your own risk)

WHAT YOU NEED
  - Windows 10/11 laptop with internet (Wi-Fi is fine)
  - Ethernet cable from the laptop directly to the controller
  - Your myBeckhoff account (e-mail + password)

HOW TO USE
  1. Double-click  BeckhoffRTLinuxSetup.cmd
     (if Windows shows "protected your PC": More info -> Run anyway)
  2. Accept the disclaimer.
  3. Pick the Ethernet adapter -> Discover -> the controller appears.
  4. Enter the Administrator password (factory default: 1) -> Connect.
     The FIRST time a black window opens asking for that password again:
     type it, press Enter. This installs an SSH key; it will not ask again.
  5. Fill in myBeckhoff login, an HMI password, DHCP or static IP.
  6. Run setup. Keep the laptop online and the window open until it finishes.

The tool installs TwinCAT runtime, TF2000 HMI Server and TF1200 UI Client,
initializes the HMI server, opens port 2020, and applies your IP choice.
