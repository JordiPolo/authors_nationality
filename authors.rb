# -*- coding: UTF-8 -*-
require 'net/http'
require 'json'

BOOKS_FILE = 'goodreads_export.csv'
BIRTHPLACE_FILE = 'birthplaces.json'

#This class manages the exported file from GoodReads.
class GoodReadsExport
  def self.get_authors
    contents = File.read(BOOKS_FILE)

    all_books = contents.split("\n")
    books = all_books.delete_if{|book_info| book_info.include?('to-read')}
    # get rid of the headers
    books.shift

    # split by "  because every field text is surrounded by quotes, it is better than commas
    # because we are having commas everywhere
    authors = books.map{|book| book.split("\"")[3] }
  end
end


# This class connects to DBPedia to get birhplaces of authors, data is incomplete and
# I am not using this now
class DBPediaClient

  def get_birthplace(original_author_name)
    author_name = url_friendly_name(original_author_name)
    response = Net::HTTP.get_response("dbpedia.org","/data/#{author_name}.json")
    json = JSON.parse(response.body)
    author = json && json["http://dbpedia.org/resource/#{author_name}"]
    return nil if !author
    birth = author && author["http://dbpedia.org/property/placeOfBirth"]
    unless (birth && birth[0]["value"])
      redirect = author["http://dbpedia.org/ontology/wikiPageRedirects"]
      if redirect
        new_name = redirect[0]['value'].split('/').last
        puts "redirected to #{new_name}"
        get_birthplace(new_name)
      end
    end
    birth && birth[0]["value"]
  rescue Timeout::Error => e
    puts 'TIMED OUT'
    # if we get a timeerror just ignore the data.
  end

private
  require 'cgi'
  def url_friendly_name(author_name)
    CGI.escape(author_name.gsub(' ','_'))
  end

end


# This class manages a cache file with all the results we had till now. This let us print what
# we want or search for new authors without needing to search for all the previous authors
class KnownAuthors

  def initialize
    contents = if File.exists?(BIRTHPLACE_FILE)
      File.read(BIRTHPLACE_FILE)
    else
      "[]"
    end
    @authors = JSON.parse(contents)
  end

  def filter(authors)
    return authors unless @authors
    known_authors = @authors.map{|data| data['author']}
    authors.select{|author| !known_authors.include?(author)}
  end

  def add(author, birthplace)
    @authors.push({author:author, birthplace: birthplace})
  end

  def save
    File.open(BIRTHPLACE_FILE,"w") do |f|
      f.write(@authors.uniq.to_json)
    end
  end

  def printout
    puts 'Authors:'
    @authors.each do |author|
      puts "#{author['author']} -> #{author['birthplace']}"
    end
    puts 'By country:'
    puts by_country
    puts 'Summary:'
    puts stats
  end

  def stats
     @authors.inject(Hash.new(0)) do |acc, author|
      acc[author['birthplace']] +=1
      acc
    end
  end

  def by_country
    contents = @authors.inject({}) do |acc, author|
      acc[author['birthplace']] ||= []
      acc[author['birthplace']].push author['author']
      acc
    end
  end

end

# gem install goodreads
require 'goodreads'
# This class connects to Goodreads and finds the information about the nationality
# of the author
class GoodReadsClient
  def initialize
    @client = Goodreads.new(:api_key => ENV['API_KEY'])
  end

  def get_nationality(original_author_name)
    author_data = client.author(client.author_by_name(original_author_name)['id'])
    calculate_birthplace(author_data['about'])
    sleep(1.1)
  rescue Goodreads::NotFound
    puts "#{original_author_name} not found"
    'Unknown'
  end

  private

  def nationalities
    @nationalities ||= {
      'French' => 'France',
      'English' => 'England',
      'Chinese' => 'China',
      'American' => 'USA',
      'Czech Republic' => 'Czech Republic',
      'United States of America' => 'USA',
      'Greek' => 'Greece',
      'Italian' => 'Italy',
      'Irish' => 'Ireland',
      'Spanish' => 'Spain',
      'Castilian' => 'Spain',
      'England' => 'England',
      'German' => 'Germany',
      'Wisconsin' => 'USA',
      'America' => 'USA',
      'Japanese' => 'Japan',
      'British' => 'England',
      'Austrian' => 'Austria',
      'Victorian' => 'England',
      'Utah' => 'USA'
    }
  end

  def calculate_birthplace(biography)
    nationalities.each_pair do |nationality, nation|
      if biography && biography.match(/.*#{nationality}.*/)
        return nation
      end
    end
   'Unknown'
 end
end


authors = GoodReadsExport.get_authors
unique_authors = authors.uniq
puts "Total books #{authors.size}"
puts "Total authors #{unique_authors.size}"

known_authors = KnownAuthors.new

unknown_authors = known_authors.filter(unique_authors)


goodreads = GoodReadsClient.new

unknown_authors.each do |original_author_name|
  nationality = goodreads.get_nationality(original_author_name)

  puts "#{original_author_name}  -> #{birth_place}"
  known_authors.add(original_author_name, nationality)
  known_authors.save
end

