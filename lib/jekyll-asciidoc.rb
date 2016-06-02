module Jekyll
  MIN_VERSION_3 = ::Gem::Version.new(VERSION) >= ::Gem::Version.new('3.0.0') unless defined? MIN_VERSION_3

  module AsciiDoc
    module Utils
      def self.has_front_matter?(delegate_method, asciidoc_ext_re, path)
        ::File.extname(path) =~ asciidoc_ext_re ? true : delegate_method.call(path)
      end
    end
  end

  module Converters
    class AsciiDocConverter < Converter
      IMPLICIT_ATTRIBUTES = %W(
        env=site env-site site-gen=jekyll site-gen-jekyll
        builder=jekyll builder-jekyll jekyll-version=#{::Jekyll::VERSION}
      )
      HEADER_BOUNDARY_RE = /(?<=\p{Graph})\n\n/
      STANDALONE_HEADER = %([%standalone]\n)

      safe true

      highlighter_prefix %(\n)
      highlighter_suffix %(\n)

      def initialize(config)
        @setup = false
        @config = config
        config['asciidoc'] ||= 'asciidoctor'
        asciidoc_ext = (config['asciidoc_ext'] ||= 'asciidoc,adoc,ad')
        asciidoc_ext_re = (config['asciidoc_ext_re'] = /^\.(?:#{asciidoc_ext.tr ',', '|'})$/ix)
        config['asciidoc_page_attribute_prefix'] ||= 'page'
        unless (asciidoctor_config = (config['asciidoctor'] ||= {})).frozen?
          # NOTE convert keys to symbols
          asciidoctor_config.keys.each do |key|
            asciidoctor_config[key.to_sym] = asciidoctor_config.delete(key)
          end
          asciidoctor_config[:safe] ||= 'safe'
          (asciidoctor_config[:attributes] ||= []).tap do |attributes|
            attributes.unshift('notitle', 'hardbreaks', 'idprefix', 'idseparator=-', 'linkattrs')
            attributes.concat(IMPLICIT_ATTRIBUTES)
          end
          if ::Jekyll::MIN_VERSION_3 && !config['asciidoc_require_front_matter']
            if (del_method = ::Jekyll::Utils.method(:has_yaml_header?))
              unless (new_method = ::Jekyll::AsciiDoc::Utils.method(:has_front_matter?)).respond_to?(:curry)
                new_method = new_method.to_proc # Ruby < 2.2
              end
              del_method.owner.define_singleton_method(del_method.name, new_method.curry[del_method][asciidoc_ext_re])
            end
          end
          asciidoctor_config.freeze
        end
      end

      def setup
        return if @setup
        @setup = true
        case @config['asciidoc']
        when 'asciidoctor'
          begin
            require 'asciidoctor' unless defined? ::Asciidoctor::VERSION
          rescue ::LoadError
            STDERR.puts 'You are missing a library required to convert AsciiDoc files. Please run:'
            STDERR.puts '  $ [sudo] gem install asciidoctor'
            raise ::FatalException.new('Missing dependency: asciidoctor')
          end
        else
          STDERR.puts %(Invalid AsciiDoc processor: #{@config['asciidoc']})
          STDERR.puts '  Valid options are [ asciidoctor ]'
          raise ::FatalException.new(%(Invalid AsciiDoc processor: #{@config['asciidoc']}))
        end
      end

      def matches(ext)
        ext =~ @config['asciidoc_ext_re']
      end

      def output_ext(ext)
        '.html'
      end

      def convert(content)
        return content if content.empty?
        setup
        if (standalone = content.start_with?(STANDALONE_HEADER))
          content = content[STANDALONE_HEADER.length..-1]
        end
        case @config['asciidoc']
        when 'asciidoctor'
          ::Asciidoctor.convert(content, @config['asciidoctor'].merge(header_footer: standalone))
        else
          warn 'Unknown AsciiDoc converter. Passing through unparsed content.'
          content
        end
      end

      def load_header(content)
        setup
        # NOTE merely an optimization; if this doesn't match, the header still gets isolated by the processor
        header = content.split(HEADER_BOUNDARY_RE, 2)[0]
        case @config['asciidoc']
        when 'asciidoctor'
          # NOTE return a document even if header is empty because attributes may be inherited from config
          ::Asciidoctor.load(header, @config['asciidoctor'].merge(parse_header_only: true))
        else
          warn 'Unknown AsciiDoc converter. Cannot load document header.'
        end
      end
    end
  end

  module Generators
    # Promotes select AsciiDoc attributes to Jekyll front matter
    class AsciiDocPreprocessor < Generator
      module NoLiquid
        def render_with_liquid?
          false
        end
      end

      STANDALONE_HEADER = ::Jekyll::Converters::AsciiDocConverter::STANDALONE_HEADER
      AUTO_PAGE_LAYOUT_LINE = %(:page-layout: _auto\n)

      def generate(site)
        asciidoc_converter = ::Jekyll::MIN_VERSION_3 ?
            site.find_converter_instance(::Jekyll::Converters::AsciiDocConverter) :
            site.getConverterImpl(::Jekyll::Converters::AsciiDocConverter)
        asciidoc_converter.setup
        unless (page_attr_prefix = site.config['asciidoc_page_attribute_prefix']).empty?
          page_attr_prefix = %(#{page_attr_prefix}-)
        end
        page_attr_prefix_l = page_attr_prefix.length

        site.pages.each do |page|
          if asciidoc_converter.matches(page.ext)
            preamble = page.data.key?('layout') ? '' : AUTO_PAGE_LAYOUT_LINE
            next unless (doc = asciidoc_converter.load_header(preamble + page.content))

            page.data['title'] = doc.doctitle if doc.header?
            page.data['author'] = doc.author if doc.author

            unless (adoc_front_matter = doc.attributes
                .select {|name| name.start_with?(page_attr_prefix) }
                .map {|name, val| %(#{name[page_attr_prefix_l..-1]}: #{val == '' ? '""' : val}) }).empty?
              page.data.update(::SafeYAML.load(adoc_front_matter * %(\n)))
            end

            case page.data['layout']
            when nil
              page.content = STANDALONE_HEADER + page.content unless page.data.key?('layout')
            when '', '_auto'
              page.data['layout'] = 'default'
            when false
              page.data.delete('layout')
              page.content = STANDALONE_HEADER + page.content
            end

            page.extend NoLiquid unless page.data['liquid']
          end
        end

        (::Jekyll::MIN_VERSION_3 ? site.posts.docs : site.posts).each do |post|
          if asciidoc_converter.matches(::Jekyll::MIN_VERSION_3 ? post.data['ext'] : post.ext)
            preamble = post.data.key?('layout') ? '' : AUTO_PAGE_LAYOUT_LINE
            next unless (doc = asciidoc_converter.load_header(preamble + post.content))

            post.data['title'] = doc.doctitle if doc.header?
            post.data['author'] = doc.author if doc.author
            post.data['date'] = ::DateTime.parse(doc.revdate).to_time if doc.attr? 'revdate'

            unless (adoc_front_matter = doc.attributes
                .select {|name| name.start_with?(page_attr_prefix) }
                .map {|name, val| %(#{name[page_attr_prefix_l..-1]}: #{val == '' ? '""' : val}) }).empty?
              post.data.update(::SafeYAML.load(adoc_front_matter * %(\n)))
            end

            case post.data['layout']
            when nil
              post.content = STANDALONE_HEADER + post.content unless post.data.key?('layout')
            when '', '_auto'
              post.data['layout'] = 'post'
            when false
              post.data.delete('layout')
              post.content = STANDALONE_HEADER + post.content
            end

            post.extend NoLiquid unless post.data['liquid']
          end
        end
      end
    end
  end

  module Filters
    # Convert an AsciiDoc string into HTML output.
    #
    # input - The AsciiDoc String to convert.
    #
    # Returns the HTML formatted String.
    def asciidocify(input)
      site = @context.registers[:site]
      converter = ::Jekyll::MIN_VERSION_3 ?
          site.find_converter_instance(::Jekyll::Converters::AsciiDocConverter) :
          site.getConverterImpl(::Jekyll::Converters::AsciiDocConverter)
      converter.convert(input)
    end
  end
end
