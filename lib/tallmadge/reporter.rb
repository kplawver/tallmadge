# frozen_string_literal: true

module Tallmadge
  # Colored terminal output. Rainbow.enabled is switched off by the CLI when
  # NO_COLOR is set or --no-color is passed.
  module Reporter
    module_function

    def ok(msg) = puts("#{Rainbow('✓').green} #{msg}")
    def warn(msg) = puts("#{Rainbow('!').yellow} #{msg}")
    def err(msg) = puts("#{Rainbow('✗').red} #{msg}")
    def info(msg) = puts(msg)

    def name(str) = Rainbow(str).cyan
    def dim(str) = Rainbow(str).faint

    def active_marker(active)
      active ? Rainbow("●").green : Rainbow("○").faint
    end

    # rows: array of arrays of strings. headers: optional header row.
    def table(rows, headers = nil)
      all = headers ? [headers, *rows] : rows
      return if all.empty?

      width = all.map(&:size).max
      widths = (0...width).map { |i| all.map { |row| row[i].to_s.length }.max }
      if headers
        puts row_line(headers, widths)
        puts widths.map { |w| "-" * w }.join("  ")
      end
      rows.each { |row| puts row_line(row, widths) }
    end

    def row_line(row, widths)
      row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i].to_i) }
         .join("  ").rstrip
    end
  end
end
