# -*- coding: UTF-8 -*-
require 'net/http'
require 'net/https'
require 'cgi'

require 'json'

BOOKS_FILE = 'goodreads_export.csv'
BIRTHPLACE_FILE = 'known_authors.json'
FREEBASE_KEY = ENV['GOOGLE_API_KEY'] || raise 'Please provide a Google api key in GOOGLE_API_KEY var'


class AuthorList
  attr_reader :list
  def initialize(data_array = [])
    @list = data_array.map{|author| Author.new(author)}
  end

  def add(new_author)
    existing_author = @list.select{|author| author.name == new_author.name }.first
    if existing_author
      existing_author.merge(new_author)
    else
      @list.push(new_author)
    end
    self
  end

  def serialize
    @list.map(&:serialize).to_json
  end

  def names
    @list.map(&:name)
  end

  def filter(known_authors)
    return authors unless known_authors
    @list.select do |author|
      known_author = known_authors.list.find{|a| a.name == author.name}
      if known_author && known_author.books == author.books
        false
      else
        true
      end
    end
  end

  def printout
    puts 'Authors:'
    print_names
    puts 'By country:'
    puts by_country
    puts 'Summary:'
    puts print_stats
  end

  def print_names
    @list.each do |author|
      puts "#{author.name} -> #{author.nationality}, #{author.book_count}"
    end
  end

  def print_stats
    puts "Country\t authors"
    print_sorted(count_authors_by_country)
    puts "Country\t books"
    print_sorted(count_books_by_country)
  end

  def print_totals
    book_count = @list.inject(0){|acc, author| acc+= author.book_count}
    puts "Total books #{book_count}"
    puts "Total authors #{@list.size}"
  end

private
  def names_by_country
    country_data = by_country
    country_data.each_pair{|country, authors| country_data[country] = authors.map(&:name)}
  end
  def count_authors_by_country
    country_data = by_country
    country_data.each_pair{|country, authors| country_data[country] = authors.size}
  end

  def count_books_by_country
    country_data = by_country
    country_data.each_pair{|country, authors| country_data[country] = authors.map(&:book_count).inject(0,:+)}
  end

  def print_sorted(data)
    sorted = data.sort_by {|_key, value| value}.reverse
    sorted.each do |pair|
     puts "#{pair.first}\t#{pair.last}"
    end
  end

  def by_country
    @list.inject({}) do |acc, author|
      acc[author.normalized_nationality] ||= []
      acc[author.normalized_nationality].push author
      acc
    end
  end
end



class Author
  attr_accessor :name, :books, :nationality

  def initialize(properties)
    raise 'the author needs a name' unless properties['name']
    @name = properties['name']
    @books = Array(properties['books'])
    @nationality = properties['nationality']
  end

  def merge(new_author)
    @books.push(new_author.books).flatten!
    @nationality ||= new_author.nationality
  end

  def book_count
    @books.size
  end

  def serialize
    {name: @name, nationality: @nationality, books: @books}
  end

  def normalized_nationality
    case @nationality
    when 'United States of America'
      'US'
    when 'Confederate States of America'
      'US'
    when 'United Kingdom'
      'England'
    when 'Scotland'
      'England'
    when 'Wales'
      'England'
    when 'Kingdom of Great Britain'
      'England'
    when 'Kingdom of Prussia'
      'Germany'
    when 'Russian Empire'
      'Russia'
    when 'Kingdom of Ireland'
      'Ireland'
    else
      @nationality
    end
  end

end



#This class manages the exported file from GoodReads.
class GoodReadsData
  def self.import
    contents = File.read(BOOKS_FILE)

    all_books = contents.split("\n")
    book_data = all_books.delete_if{|book_info| book_info.include?('to-read')}
    # get rid of the headers
    book_data.shift

    books = self.read_book_data(book_data)

    books.inject(AuthorList.new) do |list, book|
      list.add(Author.new('name' => book[:author], 'books' => [book[:title]]))
      list
    end
  end


  private

  def self.read_book_data(book_data)
    book_data.inject([]) do |list, book|
      # split by "  because every field text is surrounded by quotes, it is better than commas
      # because we are having commas everywhere
      author = book.split("\"")[3]
      book_title = book.split("\"")[1]
      book_type = self.book_type(book)
      list.push({author: author, title: book_title, type: book_type})
    end
  end

  def self.book_type(book_data)
    if book_data.include?('manga')
      'manga'
    else
      'book'
    end
  end
end




# This class manages a cache file with all the results we had till now. This let us print what
# we want or search for new authors without needing to search for all the previous authors
class KnownAuthors
  attr_reader :list, :unknown_list

  def initialize(filename = BIRTHPLACE_FILE)
    @filename = filename
    create_lists(read_json(read_file_contents(filename)))
  end

  def add(author)
    @list.add(author)
  end

  def save
    File.open(@filename,"w") do |f|
      f.write(@list.serialize)
    end
  end

  private
  def create_lists(authors_raw_list)
    unknown, known = authors_raw_list.partition{|author| author['nationality'] == 'Unknown'}
    @unknown_list = AuthorList.new(unknown)
    @list = AuthorList.new(known)
  end

  def read_json(contents)
    JSON.parse(contents)
  rescue JSON::ParserError
    []
  end

  def read_file_contents(filename)
    if File.exists?(filename)
      File.read(filename)
    else
      "[]"
    end
  end
end


class NationalityCalculator
  def self.get_nationality(author_name)
    return 'Unknown' if self.unknown_author?(author_name)
    FreeBaseClient.get_nationality(author_name)
  end

  private
  def self.unknown_author?(author_name)
    ['Anonymous', 'Various', 'Unknown'].include?(author_name)
  end
end


class FreeBaseClient
  def self.get_nationality(author_name)
    self.queries(author_name).inject('Unknown') do |nationality, query|
      if nationality == 'Unknown'
        nationality = self.execute_query(query)
      end
      nationality
    end
  end

  private
  def self.queries(author_name)
    question = '"/people/person/nationality":[{}]'
    queries = {
      writer: %Q{[{ "name~=": "#{author_name}", "type": "/book/author", #{question} }]},
      mangaka: %Q{[{ "name~=": "#{author_name}", "/people/person/profession": "Mangaka", #{question} }]},
      general: %Q{[{ "/common/topic/alias~=": "#{author_name}", #{question} }]}
    }.values
  end

  def self.execute_query(query)
    base_path = "https://www.googleapis.com/freebase/v1/mqlread/?key=#{FREEBASE_KEY}&query="
    uri = URI(base_path + CGI.escape(query))
    result = get_result_from_uri(uri)
    if !result.empty?
      nationalities = result[0]["/people/person/nationality"]
      # Taking the second nationality because usually the author was born somewhere
      # but soon moved on
      index = nationalities.size == 1 ? 0 : 1
      if !nationalities.empty?
        return nationalities[index]['name']
      end
    end
    "Unknown"
  end

  def self.get_result_from_uri(uri)
    response = Net::HTTP.start(uri.host, use_ssl: true) do |http|
       http.get uri.request_uri
    end
    json = JSON.parse(response.body.to_s)
    Array(json['result'])
  end

end




authors = GoodReadsData.import

known_authors = KnownAuthors.new

unknown_authors = authors.filter(known_authors.list)

unknown_authors.each do |author|
  author.nationality = NationalityCalculator.get_nationality(author.name)
  puts "#{author.name}  -> #{author.nationality}"
  known_authors.add(author)
  known_authors.save
end


puts '#####'
known_authors.list.print_stats
