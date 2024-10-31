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

    ENV["TYPELIZER"] = "true"

    puts "Generating TypeScript interfaces..."
    serializers = []
    time = Benchmark.realtime do
      serializers = block.call
    end

    puts "Finished in #{time} seconds"
    puts "Found #{serializers.size} serializers:"
    puts serializers.map { |s| "\t#{s.name}" }.join("\n")
  end
end
