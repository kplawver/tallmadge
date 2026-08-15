# frozen_string_literal: true

require "yaml"
module Tallmadge
  # The .agents protocol frontmatter is simple `---` fenced `key: value`
  # lines, not full YAML. parse handles that shape and falls back to
  # YAML.safe_load for real YAML frontmatter (e.g. existing SKILL.md files).
  module Frontmatter
    LIST_KEYS = %w[tags keywords tools allowed-tools requires].freeze

    class ParseFail < StandardError; end

    module_function

    # Returns [hash, body]. No frontmatter -> [{}, text].
    def parse(text)
      text = text.to_s
      return [{}, text] unless text.start_with?("---")

      lines = text.lines
      close_idx = lines[1..].index { |l| l.strip == "---" }
      return [{}, text] unless close_idx

      close_idx += 1 # account for the skipped first line
      fm_lines = lines[1...close_idx]
      body = lines[(close_idx + 1)..].join
      # serialize() emits exactly one blank line after the closing fence;
      # consume it so serialize->parse roundtrips.
      body = body.sub(/\A\n/, "")

      begin
        [parse_simple_lines(fm_lines), body]
      rescue ParseFail
        yaml_fallback(fm_lines.join, body, text)
      end
    end

    # Emits `---`, alphabetically sorted `key: value` lines, `---`, blank
    # line, then body.
    def serialize(hash, body)
      lines = ["---"]
      hash.keys.sort.each do |key|
        value = hash[key]
        value = value.join(", ") if value.is_a?(Array)
        lines << "#{key}: #{value}"
      end
      lines << "---"
      lines << ""
      lines.join("\n") + "\n" + body.to_s
    end

    def parse_simple_lines(fm_lines)
      hash = {}
      fm_lines.each do |line|
        next if line.strip.empty?
        # Indented lines mean nested YAML -> fall back.
        raise ParseFail if line.start_with?(" ", "\t")

        key, sep, value = line.partition(":")
        raise ParseFail if sep.empty?

        hash[key.strip] = coerce(key.strip, unquote(value.strip))
      end
      hash
    end

    def yaml_fallback(fm_text, body, original)
      data = YAML.safe_load(fm_text)
      raise ParseFail unless data.is_a?(Hash)

      [data, body]
    rescue ParseFail, Psych::SyntaxError, Psych::DisallowedClass
      [{}, original]
    end

    def unquote(value)
      if value.length >= 2 &&
         ((value.start_with?('"') && value.end_with?('"')) ||
          (value.start_with?("'") && value.end_with?("'")))
        value[1..-2]
      else
        value
      end
    end

    def coerce(key, value)
      if value.start_with?("[")
        parsed = JSON.parse(value) rescue nil
        return parsed if parsed.is_a?(Array)
      end
      return value.split(",").map(&:strip).reject(&:empty?) if LIST_KEYS.include?(key)

      value
    end
  end
end
