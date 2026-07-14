{ codex-acp, ... }:

{
  imports = [ ./common.nix ];

  llmjail.acp = true;
  llmjail.toolBinary = "${codex-acp}/bin/codex-acp";
  llmjail.dangerousFlag = "";

  environment.systemPackages = [
    codex-acp
  ];
}
