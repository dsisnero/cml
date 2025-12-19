#!/usr/bin/env crystal

require "file"
require "path"

# Simple CLI tool to extract crystal code examples from markdown
class ExampleExtractor
  property markdown_file : String
  property output_dir : String
  property examples : Array(Hash(String, String | Int32))

  def initialize(@markdown_file : String, @output_dir : String)
    @examples = [] of Hash(String, String | Int32)
  end

  def run
    puts "Extracting Crystal code examples from: #{@markdown_file}"
    puts "Output directory: #{@output_dir}"

    unless File.exists?(@markdown_file)
      puts "Error: Markdown file not found"
      exit 1
    end

    # Create output directory
    Dir.mkdir_p(@output_dir)

    # Read the file
    content = File.read(@markdown_file)

    # Find all code blocks
    blocks = extract_code_blocks(content)

    puts "Found #{blocks.size} Crystal code blocks"

    # Save each block
    blocks.each_with_index do |block, index|
      save_block(block, index + 1)
    end

    generate_summary
    puts "\nDone. Extracted #{blocks.size} examples to #{@output_dir}"
  end

  private def extract_code_blocks(content : String) : Array(Hash(String, String | Int32))
    blocks = [] of Hash(String, String | Int32)

    lines = content.lines
    in_block = false
    current_block = [] of String
    start_line = 0
    current_section = "unknown"

    lines.each_with_index do |line, line_num|
      line_num_1based = line_num + 1

      # Track section headers
      if line =~ /^##[^#]/
        current_section = sanitize_section(line.sub(/^##\s*/, ""))
      end

      if !in_block && line.strip == "```crystal"
        # Start of code block
        in_block = true
        start_line = line_num_1based
        current_block.clear
      elsif in_block && line.strip == "```"
        # End of code block
        in_block = false
        blocks << {
          "section"    => current_section,
          "lines"      => current_block.join("\n"),
          "start_line" => start_line,
          "end_line"   => line_num_1based,
          "size"       => current_block.size,
        }
        current_block.clear
      elsif in_block
        # Inside code block
        current_block << line
      end
    end

    blocks
  end

  private def save_block(block : Hash(String, String | Int32), index : Int32)
    section = block["section"].as(String)
    content = block["lines"].as(String)
    start_line = block["start_line"].as(Int32)
    end_line = block["end_line"].as(Int32)

    # Generate filename
    filename = "#{section}_#{index.to_s.rjust(3, '0')}.cr"
    filepath = File.join(@output_dir, filename)

    # Add header comment
    hyphen_line = "# " + "-" * 58
    header = <<-CRYSTAL
    # #{filename}
    # Extracted from: #{File.basename(@markdown_file)}
    # Section: #{section}
    # Lines: #{start_line}-#{end_line}
    #
    #{hyphen_line}

    CRYSTAL

    # Adjust require paths from ./src/cml to ../../src/cml (since we're in examples/how_to/)
    adjusted_lines = [] of String
    content.each_line do |line|
      if line =~ /require\s+(?:".\/src\/cml[^"]*"|'\.\/src\/cml[^']*')/
        line = line.gsub(/".\/src\/cml/, "\"../../src/cml").gsub(/'\.\/src\/cml/, "'../../src/cml")
      end
      adjusted_lines << line
    end
    adjusted_content = adjusted_lines.join("\n")

    # Check if content already has require statement for CML (after adjustment)
    has_require = false
    adjusted_content.each_line do |line|
      if line =~ /require.*cml/i || line =~ /require.*src.*cml/i
        has_require = true
        break
      end
    end

    # Check if we need multicast require
    needs_multicast = adjusted_content.includes?("Multicast") || adjusted_content.includes?("multicast")

    # Check if we need linda require
    needs_linda = adjusted_content.includes?("CML::Linda") || adjusted_content.includes?("Linda")

    # Collect missing function definitions
    dummy_defs = [] of String

    # List of known function names that might be missing
    missing_functions = {
      "compute_expensive_value" => "def compute_expensive_value\n  42\nend",
      "expensive_computation"   => "def expensive_computation\n  \"result\"\nend",
      "run_process"             => "def run_process(cmd : String) : Bool\n  true\nend",
      "file_status"             => "def file_status(path : String) : Time?\n  Time.utc\nend",
      "get_mtime"               => "def get_mtime(path : String) : Time\n  Time.utc\nend",
      "parse_makefile"          => "def parse_makefile(content : String) : Array(BuildSystem::Rule)\n  [] of BuildSystem::Rule\nend",
      "make_graph"              => "def make_graph(signal_ch, rules)\n  # Dummy implementation\n  CML.mchannel(BuildSystem::Stamp).port\nend",
      "acquire_resource"        => "def acquire_resource\n  nil\nend",
      "release_resource"        => "def release_resource(resource)\nend",
    }

    missing_functions.each do |func_name, dummy_def|
      if adjusted_content =~ /\b#{func_name}\b/
        dummy_defs << dummy_def
      end
    end

    # Build preamble
    preamble = ""
    unless has_require
      preamble += "require \"../../src/cml\"\n"
    end
    if needs_multicast && !adjusted_content.includes?("require \"../../src/cml/multicast\"")
      preamble += "require \"../../src/cml/multicast\"\n"
    end
    if needs_linda && !adjusted_content.includes?("require \"../../src/cml/linda\"")
      preamble += "require \"../../src/cml/linda\"\n"
    end
    unless dummy_defs.empty?
      preamble += "\n# Dummy definitions for example compilation\n"
      preamble += dummy_defs.join("\n\n") + "\n"
    end

    full_content = header + preamble
    if !preamble.empty? && !preamble.ends_with?("\n\n")
      full_content += "\n"
    end
    full_content += adjusted_content

    File.write(filepath, full_content)

    # Record
    @examples << {
      "filename"   => filename,
      "filepath"   => filepath,
      "section"    => section,
      "start_line" => start_line,
      "end_line"   => end_line,
      "size"       => content.lines.size,
    }

    puts "  Saved: #{filename} (#{content.lines.size} lines, lines #{start_line}-#{end_line})"
  end

  private def sanitize_section(text : String) : String
    text.gsub(/[^a-zA-Z0-9_\-\s]/, "")
      .gsub(/\s+/, "_")
      .downcase
  end

  private def generate_summary
    summary_file = File.join(@output_dir, "SUMMARY.md")

    content = String.build do |str|
      str << "# Code Examples Summary\n\n"
      str << "## Source\n"
      str << "- Markdown: `#{@markdown_file}`\n"
      str << "- Output: `#{@output_dir}`\n"
      str << "- Total examples: #{@examples.size}\n\n"

      str << "## Examples\n\n"
      str << "| # | Filename | Section | Lines | Size |\n"
      str << "|---|----------|---------|-------|------|\n"

      @examples.each_with_index do |ex, idx|
        filename = ex["filename"].as(String)
        section = ex["section"].as(String)
        start_line = ex["start_line"].as(Int32)
        end_line = ex["end_line"].as(Int32)
        size = ex["size"].as(Int32)

        str << "| #{idx + 1} | `#{filename}` | #{section} | #{start_line}-#{end_line} | #{size} lines |\n"
      end
    end

    File.write(summary_file, content)
    puts "  Summary saved to: #{summary_file}"
  end
end

# Main
if ARGV.size < 2
  puts "Usage: crystal scripts/extract_examples.cr <markdown_file> <output_dir>"
  puts "Example: crystal scripts/extract_examples.cr how_to.md examples/how_to/"
  exit 1
end

markdown_file = File.expand_path(ARGV[0])
output_dir = File.expand_path(ARGV[1])

extractor = ExampleExtractor.new(markdown_file, output_dir)
extractor.run
