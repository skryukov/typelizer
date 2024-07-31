namespace :typelizer do
  desc "Generate TypeScript interfaces from serializers"
  task generate: :environment do
    require "benchmark"

    ENV["TYPELIZER"] = "true"

    puts "Generating TypeScript interfaces..."
    serializers = []
    time = Benchmark.realtime do
      serializers = Typelizer::Generator.call
    end

    puts "Finished in #{time} seconds"
    puts "Found #{serializers.size} serializers:"
    puts serializers.map { |s| "\t#{s.name}" }.join("\n")
  end
end
