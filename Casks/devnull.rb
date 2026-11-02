cask "devnull" do
  version :latest
  sha256 :no_check

  url "https://dev-null.sh/downloads/DevNull.dmg"
  name "DevNull"
  desc "Social network for devs"
  homepage "https://dev-null.sh/apps"

  depends_on macos: :sonoma

  app "DevNull.app"

  zap trash: [
    "~/Library/Caches/sh.dev-null.mac",
    "~/Library/HTTPStorages/sh.dev-null.mac",
    "~/Library/Preferences/sh.dev-null.mac.plist",
    "~/Library/Saved Application State/sh.dev-null.mac.savedState",
  ]
end
