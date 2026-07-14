{ pkgs, nixpkgs, claude-code, codex-cli, copilot-cli, claude-agent-acp, codex-acp }:

let
  mkSmokeTest = { name, guestModule, toolBinary }:
    pkgs.testers.nixosTest {
      name = "llmjail-${name}-smoke";

      nodes.machine = { lib, ... }: {
        imports = [ guestModule ];
        _module.args = { inherit nixpkgs claude-code codex-cli copilot-cli; };

        # Override 9p filesystem entries from common.nix - the test framework
        # provides its own root and /nix/store via virtualisation options.
        fileSystems."/.nix-lower/store" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "size=1M" ];
        };
        fileSystems."/llmjail-env" = lib.mkForce {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "size=10M" ];
        };
        boot.initrd.postMountCommands = lib.mkForce "";

        # Provide mock envfs contents for the mounts service
        systemd.tmpfiles.rules = [
          "d /workspace 0755 user users -"
          "f /llmjail-env/env 0644 root root - HOME=/home/user"
          "f /llmjail-env/tool-args 0644 root root -"
          "f /llmjail-env/allowed-domains 0644 root root -"
        ];

        # Tool service will fail without credentials - prevent it from
        # blocking boot or powering off the VM.
        systemd.services.llmjail-tool = {
          wantedBy = lib.mkForce [ ];
          serviceConfig.ExecStopPost = lib.mkForce "";
        };

        virtualisation.memorySize = 1024;
      };

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("tool binary exists"):
            machine.succeed("test -x ${toolBinary}")

        with subtest("systemd services are defined"):
            machine.succeed("systemctl cat llmjail-mounts.service")
            machine.succeed("systemctl cat llmjail-net-filter.service")
            machine.succeed("systemctl cat llmjail-tool.service")
            machine.succeed("systemctl cat llmjail-winsize.service")

        with subtest("winsize service is running"):
            machine.succeed("systemctl is-active llmjail-winsize.service")

        with subtest("mounts service handles no-mounts case"):
            machine.succeed("systemctl is-active llmjail-mounts.service")

        with subtest("tool service has correct configuration"):
            output = machine.succeed(
                "systemctl show llmjail-tool.service -p User,WorkingDirectory"
            )
            assert "User=user" in output, f"Expected User=user in: {output}"
            assert "WorkingDirectory=/workspace" in output, f"Expected WorkingDirectory=/workspace in: {output}"

        with subtest("common packages are available"):
            machine.succeed("which git")
            machine.succeed("which node")
            machine.succeed("which curl")
            machine.succeed("which ssh")

        with subtest("user account is configured"):
            machine.succeed("id user")
            machine.succeed("test -d /home/user")
            machine.succeed("getent passwd user | grep -q /home/user")

        with subtest("nix has flakes enabled"):
            machine.succeed("nix --version")
            machine.succeed("nix eval --expr 'true'")

        with subtest("nixpkgs is pinned in registry and NIX_PATH"):
            machine.succeed("cat /etc/nix/registry.json | grep nixpkgs")
            machine.succeed("nix-instantiate --eval -E '<nixpkgs>'")

        with subtest("user can read kernel journal"):
            machine.succeed("su - user -c 'journalctl -k --no-pager -n 1'")
      '';
    };

  netFilterTest = pkgs.testers.nixosTest {
    name = "llmjail-net-filter-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/claude.nix ];
      _module.args = { inherit nixpkgs claude-code codex-cli; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };
      boot.initrd.postMountCommands = lib.mkForce "";

      # Enable net filtering via kernel cmdline
      boot.kernelParams = lib.mkAfter [ "llmjail.net_filter=1" ];

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f+ /llmjail-env/allowed-domains 0644 root root - api.anthropic.com"
      ];

      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("llmjail-net-filter.service")

      with subtest("dnsmasq is running"):
          machine.succeed("pgrep dnsmasq")

      with subtest("resolv.conf points to localhost"):
          output = machine.succeed("cat /etc/resolv.conf")
          assert "127.0.0.1" in output, f"Expected 127.0.0.1 in resolv.conf: {output}"

      with subtest("nftables rules are loaded"):
          output = machine.succeed("nft list ruleset")
          assert "llmjail_filter" in output, f"Expected llmjail_filter in nft rules: {output}"

      with subtest("dnsmasq config has allowed domain"):
          output = machine.succeed("cat /etc/dnsmasq-llmjail.conf")
          assert "api.anthropic.com" in output, f"Expected api.anthropic.com in dnsmasq config: {output}"

      with subtest("blocked domain fails to resolve"):
          machine.fail("getent hosts evil.example.com")
    '';
  };

  # ACP mode: verify the tool service is wired to the virtio port and the
  # winsize service is gone. Uses `cat` as a stand-in tool binary so the
  # test does not depend on agent packages or credentials.
  acpServiceTest = pkgs.testers.nixosTest {
    name = "llmjail-acp-service-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/common.nix ];
      _module.args = { inherit nixpkgs; };

      llmjail.acp = true;
      llmjail.toolBinary = "${pkgs.coreutils}/bin/cat";
      llmjail.dangerousFlag = "";

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };
      boot.initrd.postMountCommands = lib.mkForce "";

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f /llmjail-env/allowed-domains 0644 root root -"
      ];

      # No virtio port exists in the test VM; keep the service defined but
      # not started (same pattern as the other smoke tests).
      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("tool service targets the journal, not a TTY"):
          output = machine.succeed(
              "systemctl show llmjail-tool.service -p StandardOutput,StandardError,TTYPath,User"
          )
          assert "StandardOutput=journal" in output, f"expected journal stdout: {output}"
          assert "StandardError=journal" in output, f"expected journal stderr: {output}"
          assert "TTYPath=/dev/ttyS0" not in output, f"unexpected TTYPath: {output}"
          assert "User=user" in output, f"expected User=user: {output}"

      with subtest("winsize service does not exist in ACP mode"):
          machine.fail("systemctl cat llmjail-winsize.service")

      with subtest("mounts service still works"):
          machine.succeed("systemctl is-active llmjail-mounts.service")
    '';
  };

  claudeAcpTest = pkgs.testers.nixosTest {
    name = "llmjail-claude-acp-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/claude-acp.nix ];
      _module.args = { inherit nixpkgs claude-agent-acp; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };
      boot.initrd.postMountCommands = lib.mkForce "";

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f /llmjail-env/allowed-domains 0644 root root -"
      ];

      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("ACP adapter binary exists"):
          machine.succeed("test -x ${claude-agent-acp}/bin/claude-agent-acp")

      with subtest("tool service uses journal stdio"):
          output = machine.succeed(
              "systemctl show llmjail-tool.service -p StandardOutput,StandardError"
          )
          assert "StandardOutput=journal" in output, f"expected journal: {output}"

      with subtest("winsize service does not exist"):
          machine.fail("systemctl cat llmjail-winsize.service")
    '';
  };

  codexAcpTest = pkgs.testers.nixosTest {
    name = "llmjail-codex-acp-smoke";

    nodes.machine = { lib, ... }: {
      imports = [ ../guests/codex-acp.nix ];
      _module.args = { inherit nixpkgs codex-acp; };

      fileSystems."/.nix-lower/store" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=1M" ];
      };
      fileSystems."/llmjail-env" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "size=10M" ];
      };
      boot.initrd.postMountCommands = lib.mkForce "";

      systemd.tmpfiles.rules = [
        "d /workspace 0755 user users -"
        "f /llmjail-env/env 0644 root root - HOME=/home/user"
        "f /llmjail-env/tool-args 0644 root root -"
        "f /llmjail-env/allowed-domains 0644 root root -"
      ];

      systemd.services.llmjail-tool = {
        wantedBy = lib.mkForce [ ];
        serviceConfig.ExecStopPost = lib.mkForce "";
      };

      virtualisation.memorySize = 1024;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("ACP adapter binary exists"):
          machine.succeed("test -x ${codex-acp}/bin/codex-acp")

      with subtest("tool service uses journal stdio"):
          output = machine.succeed(
              "systemctl show llmjail-tool.service -p StandardOutput,StandardError"
          )
          assert "StandardOutput=journal" in output, f"expected journal: {output}"

      with subtest("winsize service does not exist"):
          machine.fail("systemctl cat llmjail-winsize.service")
    '';
  };

in
{
  claude-smoke = mkSmokeTest {
    name = "claude";
    guestModule = ../guests/claude.nix;
    toolBinary = "${claude-code}/bin/claude";
  };

  codex-smoke = mkSmokeTest {
    name = "codex";
    guestModule = ../guests/codex.nix;
    toolBinary = "${codex-cli}/bin/codex";
  };

  copilot-smoke = mkSmokeTest {
    name = "copilot";
    guestModule = ../guests/copilot.nix;
    toolBinary = pkgs.lib.getExe copilot-cli;
  };

  net-filter-smoke = netFilterTest;

  acp-service-smoke = acpServiceTest;

  claude-acp-smoke = claudeAcpTest;

  codex-acp-smoke = codexAcpTest;
}
