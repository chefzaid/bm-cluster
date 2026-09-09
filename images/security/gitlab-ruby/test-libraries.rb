#!/usr/bin/env ruby
require 'json'
require 'nokogiri'
require 'websocket/driver'
require 'graphql'
require 'mail'
require 'ethon'
require 'prawn'
require 'prawn-svg'
require 'premailer'

raise 'JSON round trip failed' unless JSON.parse(JSON.generate({ 'ok' => true }))['ok']
raise 'HTML parser failed' unless Nokogiri::HTML5.fragment('<p>fixture</p>').text == 'fixture'
raise 'GraphQL parser failed' unless GraphQL.parse('{ __typename }').definitions.size == 1
raise 'Vendor libcurl unavailable' unless Ethon::Curl.version.start_with?('libcurl/')
pdf = Prawn::Document.new
pdf.svg('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="50" height="50" fill="red"/></svg>',
        enable_web_requests: false)
raise 'SVG PDF rendering failed' unless pdf.render.start_with?('%PDF-')
html = Premailer.new('<html><head><style>p { color: red; }</style></head><body><p>fixture</p></body></html>',
                     with_html_string: true).to_inline_css
raise 'CSS inlining failed' unless html.include?('color: red')
puts 'Native libraries, parsers, PDF rendering and CSS inlining passed'
