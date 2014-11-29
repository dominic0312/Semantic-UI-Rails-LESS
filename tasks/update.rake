require 'pathname'
require 'json'
require 'active_support/all'

namespace :update do

  desc 'Update Semantic UI version'
  task :version, [:version] do |_, args|
    version = args[:version]

    checkout_repository
    choose_version(version)

    transform_sources
  end

  def paths
    @gem_paths ||= Paths.new
  end

  def checkout_repository
    if Dir.exist?(paths.tmp_semantic_ui)
      sh %Q{cd '#{paths.tmp_semantic_ui}' && git fetch --quiet}
    else
      sh %Q{git clone --quiet git@github.com:Semantic-Org/Semantic-UI.git '#{paths.tmp_semantic_ui}'}
    end
  end

  def choose_version(version)
    sh %Q{cd '#{paths.tmp_semantic_ui}' && git checkout --quiet #{version}}
  end

  def transform_sources
    transform_definitions
    transform_themes

    apply_patches

    generate_semantic_ui_js
    generate_semantic_ui_css
  end

  def transform_definitions
    Dir[File.join(paths.tmp_semantic_ui_definitions, '**/*.js')].each do |src|
      copy_tree(src, File.dirname(paths.tmp_semantic_ui_definitions), paths.javascripts)
    end

    Dir[File.join(paths.tmp_semantic_ui_definitions, '**/*.less')].each do |src|
      copy_tree(src, File.dirname(paths.tmp_semantic_ui_definitions), paths.stylesheets)
    end
  end

  def transform_themes
    Dir[File.join(paths.tmp_semantic_ui_themes, '**/*.{eot,otf,svg,ttf,woff}')].each do |src|
      copy_tree(src, File.dirname(paths.tmp_semantic_ui_themes), paths.fonts)
    end

    Dir[File.join(paths.tmp_semantic_ui_themes, '**/*.{png,gif}')].each do |src|
      copy_tree(src, File.dirname(paths.tmp_semantic_ui_themes), paths.images)
    end

    Dir[File.join(paths.tmp_semantic_ui_themes, '**/*.{overrides,variables}')].each do |src|
      copy_tree(src, File.dirname(paths.tmp_semantic_ui_themes), paths.stylesheets)
    end

    cp(File.join(paths.tmp_semantic_ui_src, 'theme.less'), paths.stylesheets)

    cp(File.join(paths.tmp_semantic_ui_src, 'theme.config.example'), File.join(paths.generator_templates, 'theme.config'))

    Dir[File.join(paths.tmp_semantic_ui_site, '**/*.{overrides,variables}')].each do |src|
      copy_tree(src, paths.tmp_semantic_ui_site, File.join(paths.generator_templates, 'config'))
    end
  end

  def apply_patches
    patch_crlf_to_lf

    patch_theme_config
    patch_paths_to_theme_config
    patch_dependencies_in_less

    patch_asset_paths
    patch_asset_helpers
  end

  def patch_crlf_to_lf
    patch(File.join(paths.javascripts, '**/*')) do |content|
      content.encode(content.encoding, universal_newline: true)
    end

    patch(File.join(paths.stylesheets, '**/*')) do |content|
      content.encode(content.encoding, universal_newline: true)
    end
  end

  def patch_theme_config
    theme_config_file = File.join(paths.generator_templates, 'theme.config')

    patch(theme_config_file) do |content|
      content = must_be_changed(content) { |c| c.sub(%r{\/\*.*?\*\/}m, '') }
      content = must_be_changed(content) { |c| c.gsub(%q{@themesFolder : 'themes/';}, %q{@themesFolder : 'semantic_ui/themes/';}) }
      content = must_be_changed(content) { |c| c.gsub(%q{@siteFolder  : '_site/';}, %q{@siteFolder  : 'semantic_ui/config/';}) }
      must_be_changed(content) { |c| c.gsub(%q{@import "theme.less";}, %q{@import "semantic_ui/theme.less";}) }
    end
  end

  def patch_paths_to_theme_config
    patch(File.join(paths.stylesheets, 'definitions', '**/*.less')) do |content|
      must_be_changed(content) { |c| c.gsub(%q{@import '../../theme.config';}, %q{@import 'semantic_ui/theme.config';}) }
    end
  end

  def patch_dependencies_in_less
    patch(File.join(paths.stylesheets, 'definitions', '**/*.less')) do |content|
      if /@type\s*:\s*'(?<type>.*)'/ =~ content && /@element\s*:\s*'(?<element>.*)'/ =~ content
        header = <<-HEADER.strip_heredoc
          /*
           *= depend_on semantic_ui/theme.config
           *= depend_on semantic_ui/config/#{type.pluralize}/#{element}.overrides
           *= depend_on semantic_ui/config/#{type.pluralize}/#{element}.variables
           */

        HEADER

        content = header + content
      end
      content
    end
  end

  def patch_asset_paths
    patch(File.join(paths.stylesheets, 'themes', '**/*.variables')) do |content|
      content.gsub(%r{^(@\w+Path\s*:\s*")\.\.\/\.\.(.*";)$}, %q{\1semantic_ui\2})
    end
  end

  def patch_asset_helpers
    patch(File.join(paths.stylesheets, 'definitions', '**/*.less')) do |content|
      content.gsub(%r{(url\()}, %q{asset-\1})
    end
  end

  def generate_semantic_ui_js
    relative_paths = search_relative_paths(File.join(paths.tmp_semantic_ui_definitions, '**/*.js'), paths.tmp_semantic_ui_src)
    relative_paths = relative_paths.map { |relative_path| File.join('semantic_ui', relative_path) }

    content = ErbRenderer.render_file(File.join('templates', 'semantic_ui.js.erb'), relative_paths: relative_paths)
    File.write(File.join(paths.generator_templates, 'semantic_ui.js'), content)
  end

  def generate_semantic_ui_css
    relative_paths = search_relative_paths(File.join(paths.tmp_semantic_ui_definitions, '**/*.less'), paths.tmp_semantic_ui_src)
    relative_paths = relative_paths.map { |relative_path| File.join('semantic_ui', relative_path) }

    content = ErbRenderer.render_file(File.join('templates', 'semantic_ui.css.erb'), relative_paths: relative_paths)
    File.write(File.join(paths.generator_templates, 'semantic_ui.css'), content)
  end

  def search_relative_paths(file_pattern, base_dir)
    less_files = Dir[file_pattern].sort_by { |less_file| File.basename(less_file) }

    relative_paths = less_files.map do |less_file|
      Pathname(less_file).relative_path_from(Pathname(base_dir))
    end
    relative_paths.compact
  end

  private

  def copy_tree(src, src_dir, dest_dir)
    dest_relative = Pathname(src).relative_path_from(Pathname(src_dir))
    dest = File.join(dest_dir, dest_relative)

    mkdir_p File.dirname(dest) unless Dir.exist?(File.dirname(dest))
    cp_r src, dest
  end

  def patch(file_pattern, &block)
    Dir[file_pattern].each do |file|
      next if File.directory?(file)

      File.write(file, File.open(file) { |f| block.call(f.read) })
    end
  end

  def must_be_changed(content, &block)
    new_content = block.call(content)
    raise 'Content must be changed' if new_content == content
    new_content
  end

  class Paths
    attr_reader :root
    attr_reader :config

    attr_reader :tmp
    attr_reader :tmp_semantic_ui
    attr_reader :tmp_semantic_ui_src
    attr_reader :tmp_semantic_ui_definitions
    attr_reader :tmp_semantic_ui_themes
    attr_reader :tmp_semantic_ui_site

    attr_reader :fonts
    attr_reader :images
    attr_reader :javascripts
    attr_reader :stylesheets

    attr_reader :generator_templates

    def initialize
      @root = File.expand_path('..', __dir__)
      @config = File.join(@root, 'config')

      @tmp = File.join(@root, 'tmp')
      @tmp_semantic_ui = File.join(@tmp, 'semantic-ui')
      @tmp_semantic_ui_src = File.join(@tmp_semantic_ui, 'src')
      @tmp_semantic_ui_definitions = File.join(@tmp_semantic_ui_src, 'definitions')
      @tmp_semantic_ui_themes = File.join(@tmp_semantic_ui_src, 'themes')
      @tmp_semantic_ui_site = File.join(@tmp_semantic_ui_src, '_site')

      @fonts = File.join(@root, 'assets', 'fonts', 'semantic_ui')
      @images = File.join(@root, 'assets', 'images', 'semantic_ui')
      @javascripts = File.join(@root, 'assets', 'javascripts', 'semantic_ui')
      @stylesheets = File.join(@root, 'assets', 'stylesheets', 'semantic_ui')

      @generator_templates = File.join(@root, 'lib', 'generators', 'semantic_ui', 'install', 'templates')
    end
  end

  class ErbRenderer < OpenStruct
    def self.render(template, values = {})
      ErbRenderer.new(values).render(template)
    end

    def self.render_file(file, values = {})
      template = File.expand_path(file, __dir__)
      ErbRenderer.new(values).render(File.read(template))
    end

    def render(template)
      ERB.new(template, nil, '-').result(binding)
    end
  end

end
