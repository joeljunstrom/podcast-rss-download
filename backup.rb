# frozen_string_literal: true

require "fileutils"
require "rss"

require "open-uri"
require "typhoeus"
require "pry"
require "active_support/all"
require "reverse_markdown"
require "progress_bar"

target_directory = "episodes"

FileUtils.mkdir_p(target_directory)

RemoteEpisode =
  Struct.new(
    :title,
    :description,
    :audio_url,
    :image_url,
    :duration,
    :published_at,
    keyword_init: true
  ) do
    def identifier
      title.parameterize
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
  end

puts "Preparing…"

episodes =
  URI.open("https://feeds.acast.com/public/shows/5af195bb77c1746339e08ab6") do |rss|
    episodes =
      RSS::Parser.parse(rss).items.map { |item|
        RemoteEpisode.new(
          title: item.title,
          description: item.description,
          audio_url: item.enclosure.url,
          duration: item.itunes_duration&.content,
          published_at: item.pubDate
        )
      }
  end

puts "— Episodes information read, downloading."

progress = ProgressBar.new(episodes.size)
hydra = Typhoeus::Hydra.new(max_concurrency: 50)

episodes.sort_by(&:published_at).each_with_index do |episode, index|
  filename = "#{index + 1}-#{episode.identifier}"
  File.write(
    File.join(target_directory, "#{filename}.txt"),
    episode.content
  )

  audio_request = Typhoeus::Request.new(episode.audio_url, followlocation: true)

  audio_file =
    File.open(
      File.join(
        target_directory,
        "#{filename}#{File.extname(episode.audio_url)}"
      ),
      "wb"
    )

  audio_request.on_headers do |response|
    if response.code != 200
      puts "Request failed for episode #{episode.identifier}"
    end
  end

  audio_request.on_body do |chunk|
    audio_file.write(chunk)
  end

  audio_request.on_complete do |response|
    progress.increment!

    audio_file.close
  end

  hydra.queue audio_request
end

hydra.run
