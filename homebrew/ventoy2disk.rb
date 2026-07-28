cask "ventoy2disk" do
  version "VERSION_PLACEHOLDER"
  sha256 "SHA256_PLACEHOLDER"

  url "https://github.com/fcjr/ventoy-mac/releases/download/v#{version}/Ventoy2Disk-#{version}.zip"
  name "Ventoy2Disk"
  desc "Install Ventoy on a USB drive"
  homepage "https://github.com/fcjr/ventoy-mac"

  depends_on macos: ">= :sonoma"

  app "Ventoy2Disk.app"

  zap trash: [
    "~/Library/Caches/com.leftshift.ventoy",
    "~/Library/Preferences/com.leftshift.ventoy.app.plist",
  ]
end
