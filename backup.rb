# frozen_string_literal: true

require "fileutils"
require "rss"

require "open-uri"
require "typhoeus"
require "pry"
require "active_support/all"
require "reverse_markdown"
require "progress_bar"

RemoteEpisode =
  Struct.new(
    :episode_number,
    :title,
    :description,
    :audio_url,
    :image_url,
    :duration,
    :published_at,
    keyword_init: true
  ) {
    def self.from(source)
      URI.open(source) do |rss|
        RSS::Parser
          .parse(rss)
          .items
          .sort_by(&:pubDate)
          .map.with_index { |item, index|
            RemoteEpisode.new(
              episode_number: index + 1,
              title: item.title,
              description: item.description,
              audio_url: item.enclosure.url,
              duration: item.itunes_duration&.content,
              published_at: item.pubDate
            )
          }
      end
    end

    def identifier
      "#{episode_number}-#{title.parameterize}"
    end

    def filename(extname)
      "#{identifier}#{extname}"
    end

    def audio_format
      File.extname(audio_url)
    end

    def content
      <<~CONTENT
        #{title}
        
        #{published_at.strftime("%Y-%m-%d %H:%M")} - #{duration}
        
        #{description_in_markdown}
      CONTENT
    end

    def description_in_markdown
      ReverseMarkdown
        .convert(description)
        .gsub("&nbsp;", " ")
    end
  }

class Downloader
  def push(source, target, &block)
    request = Typhoeus::Request.new(source, followlocation: true)
    target_file = File.open(target, "wb")

    request.on_headers do |response|
      if response.code != 200
        puts "Request failed for episode #{source}"
      end
    end

    request.on_body do |chunk|
      target_file.write(chunk)
    end

    request.on_complete do |response|
      target_file.close

      block&.call
    end

    hydra.queue(request)
  end

  def run
    hydra.run
  end

  private

  def hydra
    @hydra ||= Typhoeus::Hydra.new(max_concurrency: 50)
  end
end

puts "Preparing…"

target_directory = "episodes"
FileUtils.mkdir_p(target_directory)

episodes =
  RemoteEpisode.from(
    "https://feeds.acast.com/public/shows/5af195bb77c1746339e08ab6"
  )
progress = ProgressBar.new(episodes.size + 1)
downloader = Downloader.new

episodes.each do |episode|
  text_target_location =
    File.join(target_directory, episode.filename(".txt"))
  audio_target_location =
    File.join(target_directory, episode.filename(episode.audio_format))

  File.write(text_target_location, episode.content)
  downloader
    .push(episode.audio_url, audio_target_location) { progress.increment! }
end

puts "— Episodes information read, downloading."

downloader.run
