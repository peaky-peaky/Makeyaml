require 'csv'
require 'fileutils'


  FileUtils.touch('sample1.yml')

  File.open("sample1.yml", "w") do |f| 
  f.puts("Hello, World!")
  end

CSV.foreach("isilon1.csv") do |row|
      p row[0]
end
