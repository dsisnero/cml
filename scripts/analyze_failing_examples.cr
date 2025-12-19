#!/usr/bin/env crystal

require "file"
require "process"

# Analyze and separate failing examples from how_to

class ExampleAnalyzer
  property source_dir : String
  property working_dir : String
  property failing_dir : String
  property issues_dir : String

  def initialize(source_dir : String, working_dir : String = "examples/how_to")
    @source_dir = File.expand_path(source_dir)
    @working_dir = File.expand_path(working_dir)
    @failing_dir = File.join(@working_dir, "failing")
    @issues_dir = File.join(@working_dir, "issues")
  end

  def run
    puts "=== Analyzing examples in #{@source_dir} ==="

    # Create directories
    Dir.mkdir_p(@failing_dir)
    Dir.mkdir_p(@issues_dir)

    # Get all .cr files
    files = Dir.glob(File.join(@source_dir, "*.cr"))

    puts "Found #{files.size} example files"

    failing = [] of Hash(String, String?)
    working = [] of String

    files.each do |file|
      basename = File.basename(file)

      puts "\n--- Testing #{basename} ---"

      # Try to compile
      result = compile_file(file)

      if result["success"].as(Bool)
        puts "  ✓ Compiles successfully"
        working << basename
      else
        puts "  ✗ Fails to compile"
        error_msg = result["error"].as?(String)
        if error_msg
          puts "    Error: #{error_msg.lines.first?}"
        end

        # Move to failing directory
        dest_file = File.join(@failing_dir, basename)
        File.rename(file, dest_file)

        # Create issue file
        issue_file = File.join(@issues_dir, basename.gsub(/\.cr$/, ".md"))
        create_issue_file(issue_file, dest_file, error_msg)

        failing << {
          "filename"   => basename,
          "error"      => error_msg.try(&.lines.first?) || "Unknown error",
          "issue_file" => File.basename(issue_file),
        } of String => String?
      end
    end

    # Generate reports
    generate_reports(working, failing)

    puts "\n=== Analysis Complete ==="
    puts "Working examples: #{working.size}"
    puts "Failing examples: #{failing.size}"
    puts "\nFailing examples moved to: #{@failing_dir}"
    puts "Issue reports in: #{@issues_dir}"
  end

  private def compile_file(file : String) : Hash(String, Bool | String?)
    output = IO::Memory.new
    error = IO::Memory.new

    # Try to compile with --no-codegen to just check syntax/semantics
    process = Process.new("crystal", ["build", "--no-codegen", file], output: output, error: error)
    status = process.wait

    error_str = error.to_s
    {
      "success" => status.success?,
      "output"  => output.to_s,
      "error"   => error_str.empty? ? nil : error_str,
    }
  end

  private def create_issue_file(issue_file : String, example_file : String, error_output : String?)
    # Read file content before moving it
    example_content = File.read(example_file)

    content = <<-MARKDOWN
    # #{File.basename(example_file)} - Compilation Issue

    ## Source File
    `#{example_file}`

    ## Error
    ```text
    #{error_output || "No error output"}
    ```

    ## Example Content
    ```crystal
    #{example_content}
    ```

    ## Analysis Needed
    1. Identify the root cause of the compilation error
    2. Determine if it's a:
       - Syntax issue in the example
       - Missing dependency or require
       - Type system limitation
       - API change needed
    3. Propose a fix

    MARKDOWN

    File.write(issue_file, content)
  end

  private def generate_reports(working : Array(String), failing : Array(Hash(String, String?)))
    # Summary report
    summary_file = File.join(@working_dir, "compilation_report.md")

    content = String.build do |str|
      str << "# How-To Examples Compilation Report\n\n"
      str << "Generated: #{Time.utc}\n\n"

      str << "## Summary\n"
      str << "- Total examples: #{working.size + failing.size}\n"
      str << "- Working: #{working.size}\n"
      str << "- Failing: #{failing.size}\n"
      str << "- Success rate: #{working.size * 100 // (working.size + failing.size)}%\n\n"

      str << "## Working Examples\n"
      working.each do |filename|
        str << "- `#{filename}`\n"
      end
      str << "\n"

      str << "## Failing Examples\n"
      failing.each do |fail|
        filename = fail["filename"].as(String)
        error = fail["error"]
        issue_file = fail["issue_file"].as(String)
        str << "### `#{filename}`\n"
        str << "- Error: `#{error}`\n"
        str << "- Issue report: [#{issue_file}](../issues/#{issue_file})\n\n"
      end

      str << "## Next Steps\n"
      str << "1. Examine failing examples in `failing/` directory\n"
      str << "2. Review issue reports in `issues/` directory\n"
      str << "3. Fix compilation issues incrementally\n"
      str << "4. Update extraction script to handle edge cases\n"
    end

    File.write(summary_file, content)
    puts "  Report saved to: #{summary_file}"

    # Detailed failing list
    failing_file = File.join(@working_dir, "failing_examples.txt")
    File.write(failing_file, failing.map { |f| f["filename"] }.join("\n"))
  end
end

# Main
if ARGV.size < 1
  puts "Usage: crystal scripts/analyze_failing_examples.cr <source_directory> [working_directory]"
  puts "Example: crystal scripts/analyze_failing_examples.cr examples/how_to"
  puts "Example: crystal scripts/analyze_failing_examples.cr examples/how_to examples/how_to"
  exit 1
end

source_dir = File.expand_path(ARGV[0])
working_dir = ARGV.size > 1 ? File.expand_path(ARGV[1]) : source_dir

unless File.exists?(source_dir)
  puts "Error: Source directory not found: #{source_dir}"
  exit 1
end

analyzer = ExampleAnalyzer.new(source_dir, working_dir)
analyzer.run