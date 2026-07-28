cask "ventoy2disk-cli" do
  version "VERSION_PLACEHOLDER"
  sha256 "SHA256_PLACEHOLDER"

  url "https://github.com/fcjr/ventoy-mac/releases/download/v#{version}/ventoy2disk-#{version}-macos.tar.gz"
  name "ventoy2disk"
  desc "Install Ventoy on a USB drive from the command line"
  homepage "https://github.com/fcjr/ventoy-mac"

  livecheck do
    skip "Auto-generated on release."
  end

  binary "ventoy2disk"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{staged_path}/ventoy2disk"]
  end

  zap trash: "~/Library/Caches/com.leftshift.ventoy"

  caveats <<~EOS
    Writing to a raw disk device requires root:
      sudo ventoy2disk -i /dev/diskN
  EOS
end
