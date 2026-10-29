require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "yaml"

module UI
  def self.user_error!(message); raise RuntimeError, message; end
  def self.message(*); end
  def self.important(*); end
  def self.success(*); end
end

class SigningHarness
  attr_reader :lanes
  def initialize
    @lanes = {}
    path = File.expand_path("../Fastfile", __dir__)
    instance_eval(File.read(path), path)
  end
  def default_platform(*); end
  def desc(*); end
  def platform(*); yield; end
  def lane(name, &block); @lanes[name] = block; end
end

class LocalSigningTest < Minitest::Test
  def setup
    @h = SigningHarness.new
    @dir = Dir.mktmpdir("signing-test-")
    @old_env = %w[DIST_P12_PATH DIST_P12_PASSWORD_FILE ASC_PYTHON].to_h { |key| [key, ENV[key]] }
    ENV["DIST_P12_PATH"] = File.join(@dir, "existing.p12")
    ENV["DIST_P12_PASSWORD_FILE"] = File.join(@dir, "password.txt")
    File.write(ENV["DIST_P12_PATH"], "synthetic")
    File.write(ENV["DIST_P12_PASSWORD_FILE"], "synthetic-password\n")
    @commands = []
    @keychains = ["/existing/login.keychain-db"]
    commands, keychains = @commands, @keychains
    @h.define_singleton_method(:local_signing_security) do |*args|
      commands << args.map(&:dup)
      case args.first
      when "create-keychain" then File.write(args.last, "encrypted fixture")
      when "delete-keychain" then FileUtils.rm_f(args.last)
      when "list-keychains"
        if args.include?("-s")
          keychains.replace(args[(args.index("-s") + 1)..-1])
        else
          next keychains.map { |path| "\"#{path}\"\n" }.join
        end
      end
      ""
    end
  end

  def teardown
    @old_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@dir)
  end

  def test_success_imports_original_file_and_cleans_only_its_keychain
    own = nil
    assert_equal "ipa", @h.with_local_signing_keychain { |path| own = path; @keychains << "/concurrent/added.keychain-db"; "ipa" }
    refute File.exist?(own)
    assert_equal ["/existing/login.keychain-db", "/concurrent/added.keychain-db"], @keychains
    imported = @commands.find { |args| args.first == "import" }
    assert_equal ENV["DIST_P12_PATH"], imported[1]
    assert_equal "synthetic-password", imported[imported.index("-P") + 1]
    created = @commands.find { |args| args.first == "create-keychain" }
    assert_match(/\A[0-9a-f]{64}\z/, created[2])
    assert @commands.any? { |args| args.first == "set-key-partition-list" }
    refute @commands.any? { |args| args.first == "default-keychain" }
  end

  def test_build_exception_still_removes_keychain_and_preserves_original_error
    own = nil
    error = assert_raises(RuntimeError) { @h.with_local_signing_keychain { |path| own = path; raise "archive failed" } }
    assert_equal "archive failed", error.message
    refute File.exist?(own)
    assert_equal ["/existing/login.keychain-db"], @keychains
    assert_equal "delete-keychain", @commands.last.first
  end

  def test_import_failure_still_cleans_partially_prepared_keychain
    original = @h.method(:local_signing_security)
    @h.define_singleton_method(:local_signing_security) { |*args| raise "import failed" if args.first == "import"; original.call(*args) }
    assert_raises(RuntimeError) { @h.with_local_signing_keychain { flunk "must not build" } }
    assert_equal "delete-keychain", @commands.last.first
    assert_equal ["/existing/login.keychain-db"], @keychains
  end

  def test_search_list_cleanup_failure_still_attempts_keychain_deletion
    original = @h.method(:local_signing_security)
    cleanup = false
    @h.define_singleton_method(:local_signing_security) do |*args|
      raise "search list failed" if cleanup && args.first == "list-keychains"
      original.call(*args)
    end
    assert_raises(RuntimeError) { @h.with_local_signing_keychain { cleanup = true } }
    assert_equal "delete-keychain", @commands.last.first
  end

  def test_missing_asset_path_fails_before_creating_keychain
    ENV.delete("DIST_P12_PASSWORD_FILE")
    assert_raises(RuntimeError) { @h.with_local_signing_keychain { flunk } }
    assert_empty @commands
  end

  def test_security_failure_does_not_disclose_command_or_output
    status = Struct.new(:success?, :exitstatus).new(false, 51)
    real = SigningHarness.new
    Open3.stub(:capture3, ["synthetic-private-output", "synthetic-password", status]) do
      error = assert_raises(RuntimeError) { real.local_signing_security("import", "-P", "synthetic-password") }
      assert_match(/exit 51/, error.message)
      refute_match(/synthetic/, error.message)
    end
  end

  def test_allocator_uses_app_wide_script_and_rejects_non_integer_output
    calls = []
    ENV["ASC_PYTHON"] = "/synthetic/python"
    @h.define_singleton_method(:sh) { |*args| calls << args; "48\n" }
    assert_equal 48, @h.next_app_build_number
    assert_equal "/synthetic/python", calls[0][0]
    assert calls[0][1].end_with?("/scripts/asc-next-build.py")
    ["", "0", "48 warning", "-1"].each do |value|
      @h.define_singleton_method(:sh) { |*| value }
      assert_raises(RuntimeError) { @h.next_app_build_number }
    end
  end

  def test_local_build_uses_same_keychain_for_archive_and_guards_exported_ipa
    options = nil
    @h.define_singleton_method(:check_release_environment) {}
    @h.define_singleton_method(:sh) { |*| "" }
    @h.define_singleton_method(:build_app) { |value| options = value; "/synthetic/Workdeck.ipa" }
    @h.define_singleton_method(:check_release_ipa) { |path| raise "IPA rejected" }
    assert_raises(RuntimeError) { @h.build_local_ipa(1) }
    args = Shellwords.split(options[:xcargs])
    assert_equal "CURRENT_PROJECT_VERSION=1", args[0]
    keychain = @commands.find { |command| command.first == "create-keychain" }.last
    assert_equal "OTHER_CODE_SIGN_FLAGS=--keychain #{Shellwords.escape(keychain)}", args[1]
    assert_equal "delete-keychain", @commands.last.first
    assert_equal 3, options[:export_options][:provisioningProfiles].length
  end

  def test_both_existing_local_lanes_allocate_app_wide_and_only_upload_after_build
    assert_equal [:beta, :release, :ci_appstore], @h.lanes.keys
    [:beta, :release].each do |lane|
      calls = []
      @h.define_singleton_method(:check_release_compatibility) { calls << :compatibility }
      @h.define_singleton_method(:asc_key) { :key }
      @h.define_singleton_method(:next_app_build_number) { calls << :allocate; 48 }
      @h.define_singleton_method(:build_local_ipa) { |number| calls << [:build, number]; "built.ipa" }
      @h.define_singleton_method(:upload_to_testflight) { |args| calls << [:upload, args[:ipa]] }
      @h.lanes[lane].call
      assert_equal [:compatibility, :allocate, [:build, 48], [:upload, "built.ipa"]], calls
      @h.define_singleton_method(:build_local_ipa) { |number| raise "archive failed" }
      calls.clear
      assert_raises(RuntimeError) { @h.lanes[lane].call }
      assert_equal [:compatibility, :allocate], calls
    end
  end

  def test_every_upload_lane_stops_before_credentials_or_signing_when_compatibility_fails
    [:beta, :release, :ci_appstore].each do |lane|
      calls = []
      @h.define_singleton_method(:sh) do |*args|
        calls << args
        raise "Compatibility rejected"
      end
      @h.define_singleton_method(:asc_key) { flunk "must not read upload credentials" }
      @h.define_singleton_method(:setup_ci) { flunk "must not import signing credentials" }
      error = assert_raises(RuntimeError) { @h.lanes[lane].call }
      assert_equal "Compatibility rejected", error.message
      assert_equal "python3", calls.first.first
      assert calls.first[1].end_with?("/scripts/check-ios-compatibility.py")
    end
  end

  def test_ordinary_push_cannot_upload_and_release_job_depends_on_native_matrix
    root = File.expand_path("../..", __dir__)
    workflow = YAML.load_file(File.join(root, ".github/workflows/appstore-build.yml"))
    compatibility = workflow.fetch("jobs").fetch("compatibility")
    upload = workflow.fetch("jobs").fetch("build-upload")
    trigger = "contains(github.event.head_commit.message, '[appstore]')"
    assert_equal trigger, compatibility.fetch("if")
    assert_equal trigger, upload.fetch("if")
    assert_equal "compatibility", upload.fetch("needs")
    assert_equal "./.github/workflows/ios-auth-check.yml", compatibility.fetch("uses")
  end
end
