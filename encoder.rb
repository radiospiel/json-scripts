require "bundler/inline"

JSON_VERSION = ENV["JSON_VERSION"]
VERSION_LABEL = ENV["VERSION_LABEL"]

gemfile do
  gem "benchmark-ips"
  if JSON_VERSION
    gem "json", JSON_VERSION
  else
    gem "json", path: ".."
  end
  gem "date"
  gem "oj", require: false
end

begin
  require "oj"
  Oj.default_options = Oj.default_options.merge(mode: :compat)
rescue LoadError
end

Oj.default_options = Oj.default_options.merge(mode: :compat)

if ENV["ONLY"]
  RUN = ENV["ONLY"].split(/[,: ]/).map{|x| [x.to_sym, true] }.to_h
  RUN.default = false
elsif ENV["EXCEPT"]
  RUN = ENV["EXCEPT"].split(/[,: ]/).map{|x| [x.to_sym, false] }.to_h
  RUN.default = true
else
  RUN = Hash.new(true)
end

def json_generate_with_flags(flags, m)
  
ensure
  if defined?(JSON::Ext.flags)
    JSON::Ext.flags = 0
  end
end

unless defined?(JSON.load_file)
  def JSON.load_file(path)
    JSON.load(File.read(path))
  end
end

def implementations(ruby_obj)
  state = JSON::State.new(JSON.dump_default_options)
  coder = JSON::Coder.new if defined?(JSON::Coder)
  implementations = {
    json: ["json (#{VERSION_LABEL || "local"})", proc { JSON.generate(ruby_obj) }],
    json_coder: ["json_coder", proc { coder.dump(ruby_obj) }],
  }

  if defined?(Oj)
    implementations[:oj] = ["oj", proc { Oj.dump(ruby_obj) }]
  end

  implementations
end

def perform_benchmark(benchmark_name, ruby_obj, check_expected: true, except: [])
  json_output = JSON.dump(ruby_obj)
  puts "== Encoding #{benchmark_name} (#{json_output.bytesize} bytes)"

  impls = implementations(ruby_obj).select { |name| RUN[name] }
  Array(except).each do |excepted_impl|
    case excepted_impl
    when Regexp then  impls = impls.reject { |i| excepted_impl.match?(i) }
    else              impls.delete excepted_impl
    end
  end

  Benchmark.ips do |x|
    expected = ::JSON.dump(ruby_obj) if check_expected
    impls.values.each do |name, block|
      begin
        result = block.call
        if check_expected && expected != result
          puts "#{name} does not match expected output. Skipping"
          puts "Expected:" + '-' * 40
          puts expected
          puts "Actual:" + '-' * 40
          puts result
          puts '-' * 40
          next
        end
      rescue => error
        puts "#{benchmark_name}: #{name} unsupported: (#{error})"
        next
      end
      x.report(name, &block)
    end
    x.compare!(order: :baseline)
  end
  puts
end

# --- benchmark groups --------------------------------------------------------

BENCHMARKS = {}
def benchmark_encoding(name, ruby_obj, check_expected: true, except: [])
  BENCHMARKS[name] = [ruby_obj, check_expected, except]
end

def perform_benchmarks(name)
  if name == "all"
    benchmarks = BENCHMARKS.
      sort_by { |name, (ruby_obj, check_expected, except)| name }.
      each do |name, (ruby_obj, check_expected, except)|
        perform_benchmark name, ruby_obj, check_expected: check_expected, except: except
      end
    return
  end

  if name.end_with?('*')
    benchmarks = BENCHMARKS.
      select { |benchmark_name, _| benchmark_name.start_with?(name) }
    benchmarks = BENCHMARKS.
      select { |benchmark_name, _| File.fnmatch(name, benchmark_name) }.
      sort_by { |name, (ruby_obj, check_expected, except)| name }.
      each do |name, (ruby_obj, check_expected, except)|
        perform_benchmark name, ruby_obj, check_expected: check_expected, except: except
      end
    return
  end

  # find and combine all benchmarks matching "name*".
  benchmarks = BENCHMARKS.
    select { |benchmark_name, _| benchmark_name.start_with?(name) }

  # get the ruby values
  ruby_objs = benchmarks.map { |_, (ruby_obj, _, _)| ruby_obj }
    
  # Normalizing the selected payload sizes so that all test cases are of roughly
  # the same size.
  max_size = ruby_objs.map { |ruby_obj| JSON.dump(ruby_obj).bytesize }.max
  
  # STDERR.puts "Normalize to #{max_size} byte"
  ruby_objs = ruby_objs.map do |ruby_obj|
    Array(ruby_obj) * (1 + (max_size - 1) / JSON.dump(ruby_obj).bytesize)
  end

  # find implementations to except
  excepts = BENCHMARKS.map do |key, values|
    values.map { |_, _, check_expected, except| except }
  end.flatten.uniq.compact

  perform_benchmark name, ruby_objs, check_expected: false, except: excepts
end

# NB: Notes are based on ruby 3.3.4 (2024-07-09 revision be1089c8ec) +YJIT [arm64-darwin23]

# On the first two micro benchmarks, the limitting factor is the fixed cost of initializing the
# generator state. Since `JSON.generate` now lazily allocate the `State` object we're now ~10-20% faster
# than `Oj.dump`.
benchmark_encoding "small.mixed", [1, "string", { a: 1, b: 2 }, [3, 4, 5]]
benchmark_encoding "small.array", [[1,2,3,4,5]]*10
benchmark_encoding "small.hash", { "username" => "jhawthorn", "id" => 123, "event" => "wrote json serializer" }

# On string encoding we're ~20% faster when dealing with mostly ASCII, but ~50% slower when dealing
# with mostly multi-byte characters. There's likely some gains left to be had in multi-byte handling.
benchmark_encoding "strings.mixed", ([("a" * 5000) + "€" + ("a" * 5000)] * 5)
benchmark_encoding "strings.multibyte", ([("€" * 3333)] * 5)
benchmark_encoding "strings.ascii", ([("abcd" * 64)] * 500)
benchmark_encoding "strings.escapes", ([("escapingsmus" * 32 + "-es\"ca\\pismus-" + "escapingsmus" * 32)] * 500)
benchmark_encoding "strings.short", ([("b" * 5) + "€" + ("a" * 5)] * 500)
benchmark_encoding "strings.tests", %w(a 12 1234 666666 7777777 72kjsh9817jkshiuz) * 500

benchmark_encoding "bytes.worst", ([("\"" * 16)] * 500)
benchmark_encoding "bytes.best", ([("." * 16)] * 500)

benchmark_encoding "symbols.sym", [:a, :"12", :"1234", :"666666", :"7777777", :"72kjsh9817jkshiuz"] * 500
benchmark_encoding "symbols.map", [{one: "1", two: "zwei", fourtytwo: "truth"}] * 500
benchmark_encoding "symbols.str", ["a", "12", "1234", "666666", "7777777", "72kjsh9817jkshiuz"] * 500

# one negative and one positive test case per # of digits
INTEGER_TESTCASES = [
                     0,
                    -1,                    1,
                   -21,                   21,
                  -321,                  456,
                 -4321,                 4321,
                -54321,                54321,
               -654321,               654321,
              -7654321,              7654321,
             -87654321,             87654321,
            -987654321,            987654321,
           -1087654321,           1087654321,
          -10000000000,          10000000000,
         -210000000000,         210000000000,
        -3210000000000,        3210000000000,
       -43210000000000,       43210000000000,
      -543210000000000,      543210000000000,
     -6543210000000000,     6543210000000000,
    -76543210000000000,    76543210000000000,
   -876543210000000000,   876543210000000000,
  -9876543210000000000,  9876543210000000000,
 -10876543210000000000, 10876543210000000000,
]

# a random collection of cent amounts in a hopefully useful distribution
CENTS = [0, 1, 21, 123, 123, 456, 4321, 4321, 4321, 54321, 54321, 654321, 7654321] * 10

# On these benchmarks we perform well, we're on par or a bit better.
benchmark_encoding "ints.testcases", INTEGER_TESTCASES
benchmark_encoding "ints.cents", CENTS
benchmark_encoding "ints.2-digits", (0..100).to_a
benchmark_encoding "ints.7-digits", (1_000_000..1_001_000).to_a
benchmark_encoding "ints.19-digit", (4611686018427387603..4611686018427387903).to_a

benchmark_encoding "dumps.activitypub", JSON.load_file("#{__dir__}/../benchmark/data/activitypub.json")
benchmark_encoding "dumps.citm_catalog", JSON.load_file("#{__dir__}/../benchmark/data/citm_catalog.json")
benchmark_encoding "dumps.twitter", JSON.load_file("#{__dir__}/../benchmark/data/twitter.json")

# This benchmark spent the overwhelming majority of its time in `ruby_dtoa`. We rely on Ruby's implementation
# which uses a relatively old version of dtoa.c from David M. Gay.
# Oj in `compat` mode is ~10% slower than `json`, but in its default mode is noticeably faster here because
# it limits the precision of floats, breaking roundtriping.  That's not something we should emulate.
#
# Since a few years there are now much faster float to string implementations such as Ryu, Dragonbox, etc,
# but all these are implemented in C++11 or newer, making it hard if not impossible to include them.
# Short of a pure C99 implementation of these newer algorithms, there isn't much that can be done to match
# Oj speed without losing precision.
benchmark_encoding "floats.canada", JSON.load_file("#{__dir__}/../benchmark/data/canada.json"), check_expected: false
benchmark_encoding "floats.cents", CENTS.map { |cent| 0.01 + cent }

# We're about 10% faster when `to_json` calls are involved, but this wasn't particularly optimized, there might be
# opportunities here.
benchmark_encoding "small.many_calls", [{object: Object.new, int: 12, float: 54.3, class: Float, time: Time.now, date: Date.today}] * 20, except: %i(json_coder)

# --- perform benchmarks
# STDERR.puts "Configured benchmarks: #{BENCHMARKS.keys.sort.join(", ")}, all"

TESTCASES = ARGV.empty? ? [ "all" ] : ARGV
TESTCASES.each do |testcase|
  perform_benchmarks(testcase)
end
