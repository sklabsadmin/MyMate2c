#!/usr/bin/env ruby
#
# Adds the MythosLiveClip App Clip target to ios/Runner.xcodeproj.
#
# Written because the project was set up from a Linux session without Xcode:
# this does, in the project file, what Xcode's File > New > Target > App Clip
# does, plus the two Flutter build phases the Runner target has. It is
# idempotent (exits if the target already exists) and only needs re-running if
# the target is deleted from the project.
#
#   gem install xcodeproj
#   ruby tool/ios_add_app_clip.rb
#
# What it creates, so the result can be checked in Xcode:
#   - target MythosLiveClip, product type on-demand-install-capable
#     application, bundle id com.sklabs.mythoslive.Clip, iOS 16.0
#   - build phases in order: Run Script (xcode_backend.sh build), Sources,
#     Frameworks, Resources, Embed Frameworks, Thin Binary (embed_and_thin)
#   - sources: MythosLiveClip/AppDelegate.swift, ClipSceneDelegate.swift and
#     Runner/GeneratedPluginRegistrant.m; resources shared with Runner
#     (Main.storyboard, LaunchScreen.storyboard, Assets.xcassets)
#   - base xcconfigs Flutter/AppClip-{Debug,Release,Profile}.xcconfig
#   - FlutterGeneratedPluginSwiftPackage and StoreKit linked
#   - on Runner: a dependency on the Clip, an "Embed App Clips" phase, and
#     CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements
#   - a shared MythosLiveClip scheme with _XCAppClipURL set
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'ios', 'Runner.xcodeproj')
CLIP = 'MythosLiveClip'
TEAM = 'TG5RWCPY3K' # whatever Runner carries; Xcode rewrites it on signing

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'no Runner target'
if project.targets.any? { |t| t.name == CLIP }
  puts "#{CLIP} target already present; nothing to do"
  exit 0
end

flutter_group = project.main_group['Flutter'] or abort 'no Flutter group'
runner_group = project.main_group['Runner'] or abort 'no Runner group'

# --- the target ----------------------------------------------------------
clip = project.new_target(:application, CLIP, :ios, '16.0', nil, :swift)
clip.product_type = Xcodeproj::Constants::PRODUCT_TYPE_UTI[:application_on_demand_install_capable]

xcconfigs = {
  'Debug' => 'AppClip-Debug.xcconfig',
  'Release' => 'AppClip-Release.xcconfig',
  'Profile' => 'AppClip-Profile.xcconfig',
}
clip.build_configurations.each do |config|
  ref = flutter_group.files.find { |f| f.path == xcconfigs[config.name] } ||
        flutter_group.new_reference("Flutter/#{xcconfigs[config.name]}")
  ref.name = xcconfigs[config.name]
  ref.path = "Flutter/#{xcconfigs[config.name]}"
  ref.source_tree = '<group>'
  config.base_configuration_reference = ref
  # Mirrors Runner's per-target settings; the project-level configuration
  # supplies the rest (deployment target, warnings, SDKROOT).
  settings = {
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'CLANG_ENABLE_MODULES' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => "#{CLIP}/#{CLIP}.entitlements",
    'CODE_SIGN_STYLE' => 'Automatic',
    'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    'DEVELOPMENT_TEAM' => TEAM,
    'ENABLE_BITCODE' => 'NO',
    'INFOPLIST_FILE' => "#{CLIP}/Info.plist",
    'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.entertainment',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'MARKETING_VERSION' => '2.0.0',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.sklabs.mythoslive.Clip',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    # APPCLIP lets shared Swift be excluded with #if !APPCLIP, per Apple.
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => config.name == 'Debug' ? 'DEBUG APPCLIP' : 'APPCLIP',
    'SWIFT_OBJC_BRIDGING_HEADER' => 'Runner/Runner-Bridging-Header.h',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1',
    'VERSIONING_SYSTEM' => 'apple-generic',
  }
  settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if config.name == 'Debug'
  config.build_settings.replace(settings)
end

# --- files ---------------------------------------------------------------
clip_group = project.main_group.new_group(CLIP, CLIP)
sources = %w[AppDelegate.swift ClipSceneDelegate.swift].map { |f| clip_group.new_reference(f) }
clip_group.new_reference('Info.plist')
clip_group.new_reference("#{CLIP}.entitlements")
registrant = runner_group.files.find { |f| f.path == 'GeneratedPluginRegistrant.m' } or abort 'no GeneratedPluginRegistrant.m'
clip.add_file_references(sources + [registrant])

%w[Main.storyboard LaunchScreen.storyboard].each do |name|
  vg = runner_group.children.find { |c| c.display_name == name } or abort "no #{name}"
  clip.add_resources([vg])
end
assets = runner_group.files.find { |f| f.path == 'Assets.xcassets' } or abort 'no Assets.xcassets'
clip.add_resources([assets])

# --- build phases, in Runner's order --------------------------------------
run_script = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
run_script.name = 'Run Script'
run_script.shell_script = '/bin/sh "$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh" build'
run_script.always_out_of_date = '1'
clip.build_phases.insert(0, run_script)

embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed.name = 'Embed Frameworks'
embed.symbol_dst_subfolder_spec = :frameworks
embed.dst_path = ''
clip.build_phases << embed

thin = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
thin.name = 'Thin Binary'
thin.shell_script = '/bin/sh "$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh" embed_and_thin'
thin.always_out_of_date = '1'
thin.input_paths = ['${TARGET_BUILD_DIR}/${INFOPLIST_PATH}']
clip.build_phases << thin

# --- frameworks: the Flutter plugin Swift package and StoreKit ------------
pkg_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
pkg_dep.product_name = 'FlutterGeneratedPluginSwiftPackage'
clip.package_product_dependencies << pkg_dep
pkg_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
pkg_file.product_ref = pkg_dep
clip.frameworks_build_phase.files << pkg_file

storekit = project.frameworks_group.files.find { |f| f.path.to_s.end_with?('StoreKit.framework') }
clip.frameworks_build_phase.add_file_reference(storekit) if storekit

# new_target links Foundation by an absolute path into one SDK version
# (iPhoneOS26.0.sdk) under an "iOS" group. Runner does not do this, Swift
# links Foundation anyway, and the pinned SDK path breaks on the next Xcode.
clip.frameworks_build_phase.files.dup.each do |bf|
  next unless bf.file_ref&.path.to_s.end_with?('Foundation.framework')
  ref = bf.file_ref
  bf.remove_from_project
  ref.remove_from_project
end
ios_group = project.main_group.children.find { |c| c.display_name == 'iOS' && c.is_a?(Xcodeproj::Project::Object::PBXGroup) }
ios_group.remove_from_project if ios_group && ios_group.children.empty?
project.frameworks_group.children.each do |c|
  c.remove_from_project if c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == 'iOS' && c.children.empty?
end

# --- Runner embeds the Clip ------------------------------------------------
runner.add_dependency(clip)
embed_clips = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_clips.name = 'Embed App Clips'
embed_clips.symbol_dst_subfolder_spec = :products_directory
embed_clips.dst_path = '$(CONTENTS_FOLDER_PATH)/AppClips'
clip_product = embed_clips.add_file_reference(clip.product_reference)
clip_product.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
thin_index = runner.build_phases.index { |p| p.display_name == 'Thin Binary' } || runner.build_phases.length
runner.build_phases.insert(thin_index, embed_clips)

runner_group.new_reference('Runner.entitlements')
runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][clip.uuid] = { 'CreatedOnToolsVersion' => '15.1' }

project.save

# --- scheme ----------------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(clip)
scheme.set_launch_target(clip)
scheme.launch_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  # Xcode launches the Clip as if invoked from this link; the card is skipped.
  { key: '_XCAppClipURL', value: 'https://chat.deeploveechoes.com/c/odysseus', enabled: true },
])
scheme.save_as(PROJECT_PATH, CLIP, true)

puts "added #{CLIP} target and scheme"
