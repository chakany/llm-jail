{ claude-agent-acp, ... }:

{
  imports = [ ./common.nix ];

  llmjail.acp = true;
  llmjail.toolBinary = "${claude-agent-acp}/bin/claude-agent-acp";
  llmjail.dangerousFlag = "";

  environment.systemPackages = [
    claude-agent-acp
  ];
}
