namespace :typelizer do
  desc "Generate TypeScript interfaces from serializers"
  task types: :environment do
    benchmark_types do
      Typelizer::Generator.call(skip_check: true)
    end
  end

  desc "Regenerate all TypeScript interfaces from serializers"
  task "types:refresh": :environment do
    benchmark_types do
      Typelizer::Generator.call(force: true, skip_check: true)
    end
  end

  desc "Generate TypeScript route helpers"
  task routes: :environment do
    benchmark_routes do
      Typelizer::RouteGenerator.call(skip_check: true)
    end
  end

  desc "Regenerate all TypeScript route helpers"
  task "routes:refresh": :environment do
    benchmark_routes do
      Typelizer::RouteGenerator.call(force: true, skip_check: true)
    end
  end

  desc "Generate all TypeScript files"
  task generate: %i[types routes]

  desc "Regenerate all TypeScript files"
  task "generate:refresh": ["types:refresh", "routes:refresh"]

  def benchmark_types(&block)
    require "benchmark"

    interfaces = Typelizer.interfaces
    if interfaces.empty?
      puts "No serializers found, skipping type generation."
      return
    end

    puts "Generating TypeScript interfaces..."
    time = Benchmark.realtime { block.call }

    puts "Finished in #{time} seconds"
    puts "Found #{interfaces.size} serializers:"
    puts interfaces.map { |i| "\t#{i.name}" }.join("\n")
  end

  def benchmark_routes(&block)
    require "benchmark"

    config = Typelizer.configuration.routes
    unless config.enabled
      puts "Route generation is disabled, skipping."
      return
    end

    puts "Generating TypeScript route helpers..."
    time = Benchmark.realtime { block.call }

    puts "Finished in #{time} seconds"
    puts "Generated route helpers in #{config.output_dir}"
  end
end
