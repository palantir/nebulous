desc "Run the tests"
task :test do |t|
  sh "rm -rf tmp"
  Dir['test/*.rb'].each do |f|
    sh "ruby #{f}"
  end
end
