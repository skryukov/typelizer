namespace :typelizer do
  desc "Generate TypeScript interfaces from serializers"
  task generate: :environment do
    benchmark do
      Typelizer::Generator.call
    end
  end

  desc "Removes all files in output folder and refreshs all generate TypeScript interfaces from serializers"
  task "generate:refresh": :environment do
    benchmark do
      Typelizer::Generator.call(force: true)
    end
  end

  def benchmark(&block)
    require "benchmark"

    ENV["DISABLE_TYPELIZER"] = "false"

    puts "Generating TypeScript interfaces..."
    time = Benchmark.realtime do
      block.call
    end

    interfaces = Typelizer.interfaces
    raise ArgumentError, "No serializers found. Please ensure all your serializers include Typelizer::DSL." if interfaces.empty?

    puts "Finished in #{time} seconds"
    puts "Found #{interfaces.size} serializers:"
    puts interfaces.map { |i| "\t#{i.name}" }.join("\n")
  end
end
