#!/usr/bin/env python3
import os
import sys
from pathlib import Path

def load_persistent_config():
    config_path = Path.home() / ".procoder_config"
    if config_path.exists():
        with open(config_path, "r") as f:
            for line in f:
                if "=" in line:
                    key, value = line.strip().split("=", 1)
                    if key == "PROCODER_LLM_API_KEY" and key not in os.environ:
                        os.environ[key] = value

def main():
    # 0. Load persistent config
    load_persistent_config()
    
    # 0.1 Handle --set-key
    if len(sys.argv) > 2 and sys.argv[1] == "--set-key":
        key = sys.argv[2]
        config_path = Path.home() / ".procoder_config"
        with open(config_path, "w") as f:
            f.write(f"PROCODER_LLM_API_KEY={key}\n")
        print(f"API Key saved to {config_path}")
        sys.exit(0)

    # 1. Resolve target SOURCE_ROOT
    if len(sys.argv) > 1 and not sys.argv[1].startswith("--"):
        target_root = os.path.abspath(sys.argv[1])
    else:
        target_root = os.getcwd()
    
    if not os.path.exists(target_root):
        print(f"Error: Target path {target_root} does not exist.")
        sys.exit(1)
    
    # Change into the target directory so subprocesses (like git init) run there
    os.chdir(target_root)
    
    # 2. Check if it's a Git repository (ProCoder requirement)
    if not (Path(target_root) / ".git").exists():
        print(f"Notice: {target_root} is not a Git repository. Initializing...")
        import subprocess
        try:
            subprocess.run(["git", "init"], check=True, capture_output=True)
            subprocess.run(["git", "add", "."], check=True, capture_output=True)
            subprocess.run(["git", "commit", "-m", "Initial ProCoder commit"], check=True, capture_output=True)
            print("Successfully initialized Git repository.")
        except subprocess.CalledProcessError as e:
            print(f"Error: Failed to initialize Git repository: {e}")
            sys.exit(1)
        
    # 3. Resolve the path to the ProCoder installation (where this script lives or relative)
    # Assuming the user installs procoder in a known location
    procoder_home = os.environ.get("PROCODER_HOME")
    if not procoder_home:
        # fallback to the directory where the system was built
        procoder_home = "/home/gifted/procoder_system"
    
    # 4. Export the necessary environment variables
    os.environ["PROCODER_SOURCE_ROOT"] = target_root
    if "WORKTREE_ROOT" not in os.environ:
        os.environ["WORKTREE_ROOT"] = "/tmp/procoder_worktrees"
        
    print(f"--- ProCoder CLI ---")
    print(f"Targeting Codebase: {target_root}")
    print(f"Installation: {procoder_home}")
    print("--------------------")
    
    # 5. Hand over to the Bash launcher to handle the Mix environment
    launcher_path = Path(procoder_home) / "scripts" / "procoder_launcher.sh"
    
    # We use os.execvpe to replace the current process and preserve environments
    os.execvpe("bash", ["bash", str(launcher_path)], os.environ)

if __name__ == "__main__":
    main()
