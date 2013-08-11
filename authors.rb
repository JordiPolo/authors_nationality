# -*- coding: UTF-8 -*-
require 'net/http'
require 'net/https'
require 'cgi'

require 'json'

BOOKS_FILE = 'goodreads_export.csv'
BIRTHPLACE_FILE = 'known_authors.json'

class AuthorList
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
    @list.select{|author| !known_authors.names.include?(author.name)}
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
 #   by_country.map{|country, authors| {country => }
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
    @books = properties['books'] || []
    @nationality = properties['nationality']
  end
  def merge(new_author)
    @books.push(new_author.books).flatten
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
    when 'United Kingdom'
      'England'
    when 'Scotland'
      'England'
    when 'Wales'
      'England'
    when 'Kingdom of Prussia'
      'Germany'
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
    books = all_books.delete_if{|book_info| book_info.include?('to-read')}
    # get rid of the headers
    books.shift


    books.inject(AuthorList.new) do |list, book|
      # split by "  because every field text is surrounded by quotes, it is better than commas
      # because we are having commas everywhere
      author = book.split("\"")[3]
      book_title = book.split("\"")[1]
      list.add(Author.new('name' => author, 'books' => [book_title]))
      list
    end
  end
end


# This class manages a cache file with all the results we had till now. This let us print what
# we want or search for new authors without needing to search for all the previous authors
class KnownAuthors
  attr_reader :list, :unknown_list

  def initialize
    contents = if File.exists?(BIRTHPLACE_FILE)
      File.read(BIRTHPLACE_FILE)
    else
      "[]"
    end
    create_lists(contents)
  end

  def add(author)
    @list.add(author)
  end

  def save
    File.open(BIRTHPLACE_FILE,"w") do |f|
      f.write(@list.serialize)
    end
  end

  def create_lists(contents)
    authors = JSON.parse(contents)
    @unknown_list = AuthorList.new
    @list = authors.inject(AuthorList.new) do |list, author|
      if author['nationality'] != 'Unknown'
        list.add(Author.new(author))
      else
        @unknown_list.add(Author.new(author))
      end
      list
    end
  rescue
    @list = AuthorList.new
    @unknown_list = AuthorList.new
  end
end


class FreeBaseClient
  def self.get_nationality(author_name)
    return 'Unknown' if author_name == 'Anonymous'
    self.queries(author_name).each do |query|
      result = self.execute_query(query)
      return result if result != 'Unknown'
    end
    'Unknown'
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
    #puts author_name
    base_path = 'https://www.googleapis.com/freebase/v1/mqlread/?query='
    uri = URI(base_path + CGI.escape(query))
    response = Net::HTTP.start(uri.host, use_ssl: true) do |http|
       http.get uri.request_uri
    end
    json = JSON.parse(response.body.to_s)
    sleep 0.2
    if json["result"] && !json["result"].empty?
      nationalities = json["result"][0]["/people/person/nationality"]
      index = nationalities.size == 1 ? 0 : 1
      if !nationalities.empty?
        return nationalities[index]['name']
      end
    end
    "Unknown"
  end

end

authors = GoodReadsData.import

known_authors = KnownAuthors.new

unknown_authors = authors.filter(known_authors.list)

unknown_authors.each do |author|
  author.nationality = FreeBaseClient.get_nationality(author.name)
  puts "#{author.name}  -> #{author.nationality}"
  known_authors.add(author)
  known_authors.save
end

puts 'still unknown'
known_authors.unknown_list.print_names

