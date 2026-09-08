class Say2 < Formula
  desc "Render installed neural Siri voices from the macOS command-line"
  homepage "https://github.com/CaptainCodeAU/say2"
  url "https://github.com/CaptainCodeAU/say2.git", tag: "v1.1.0"
  license "MIT"
  head "https://github.com/CaptainCodeAU/say2.git", branch: "main"

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    system "codesign", "--force", "--sign", "-", ".build/release/say2"
    bin.install ".build/release/say2"
  end

  test do
    assert_match "say2", shell_output("#{bin}/say2 --help")
    assert_match "say2 doctor", shell_output("#{bin}/say2 doctor --skip-probe")
  end
end
