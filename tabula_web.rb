# -*- coding: utf-8 -*-
require 'cuba'
require "cuba/render"

require "docsplit" # for page thumbnails
require 'nokogiri'
require "digest/sha1"
require 'json'
require 'csv'

require './tabula.rb'
require './local_settings.rb'

Cuba.plugin Cuba::Render
Cuba.use Rack::Static, root: "static", urls: ["/css","/js", "/img", "/pdfs", "/scripts", "/swf"]

def run_pdftohtml(file, output_dir)
  `#{Settings::PDFTOHTML_PATH} -xml #{file} #{File.join(output_dir, 'document.xml')}`
end

def run_jrubypdftohtml(file, output_dir)
  `CLASSPATH=lib/jars/fontbox-1.7.1.jar:lib/jars/pdfbox-1.7.1.jar:lib/jars/commons-logging-1.1.1.jar:lib/jars/jempbox-1.7.1.jar #{Settings::JRUBY_PATH} jruby_dump_characters.rb #{file} > #{File.join(output_dir, 'document.xml')}`
end

def parse_document_xml(file)
  Nokogiri::XML(File.open(file)) # { |config| config.default_xml.noblanks }
end

def get_text_elements(file_id, page, x1, y1, x2, y2)
  xml = parse_document_xml(File.join(Dir.pwd, "static/pdfs/#{file_id}/document.xml"))
  
  text_nodes = xml.xpath("//page[@number=#{page}]//text[@top > #{y1} and (@top + @height) < #{y2} and @left > #{x1} and (@left + @width) < #{x2}]")
  
  text_nodes.map { |tn| 
    Tabula::TextElement.new(tn.attr('top').to_f, 
                            tn.attr('left').to_f, 
                            tn.attr('width').to_f,
                            tn.attr('height').to_f,
                            tn.attr('font').to_s,
                            tn.text)
  }
end

Cuba.define do

  on get do
    on root do
      res.write view("index.html", )
    end

    on "pdf/:file_id/data" do |file_id| # TODO validate that file_id is /[a-f0-9]{40}/

      text_elements = get_text_elements(file_id,
                                        req.params['page'],
                                        req.params['x1'],
                                        req.params['y1'],
                                        req.params['x2'],
                                        req.params['y2'])

      table = Tabula.make_table(text_elements, 
                                Settings::USE_JRUBY_ANALYZER,
                                req.params['split_multiline_cells'] == 'true')

      line_texts = table.map { |line| 
        line.text_elements.sort_by { |t| t.left }
      }

      if req.params['format'] == 'csv'
        res['Content-Type'] = 'text/csv'
        csv_string = CSV.generate { |csv|
          line_texts.each { |l|
            csv << l.map { |c| c.text }
          }
        }
        res.write csv_string
      else
        res['Content-Type'] = 'application/json'
        res.write line_texts.to_json
      end

    end
 
    on "pdf/:file_id/columns" do |file_id|
      text_elements = get_text_elements(file_id,
                                        req.params['page'],
                                        req.params['x1'],
                                        req.params['y1'],
                                        req.params['x2'],
                                        req.params['y2'])

      res['Content-Type'] = 'application/json'
      res.write Tabula.get_columns(text_elements, 
                              Settings::USE_JRUBY_ANALYZER).to_json

    end

    on "pdf/:file_id/rows" do |file_id|
      text_elements = get_text_elements(file_id,
                                        req.params['page'],
                                        req.params['x1'],
                                        req.params['y1'],
                                        req.params['x2'],
                                        req.params['y2'])

      res['Content-Type'] = 'application/json'
      res.write Tabula.get_rows(text_elements, 
                                Settings::USE_JRUBY_ANALYZER).to_json

    end

    on "pdf/:file_id/characters" do |file_id|
      text_elements = get_text_elements(file_id,
                                        req.params['page'],
                                        req.params['x1'],
                                        req.params['y1'],
                                        req.params['x2'],
                                        req.params['y2'])
      puts text_elements.map(&:text).inspect

      res['Content-Type'] = 'application/json'
      res.write text_elements.map { |te|
        { 'left' => te.left,
          'top' => te.top,
          'width' => te.width,
          'height' => te.height,
          'text' => te.text }
      }.to_json
    end


    on "pdf/:file_id" do |file_id| 
      # TODO validate that file_id is  /[a-f0-9]{40}/
      document_dir = File.join(Dir.pwd, "static/pdfs/#{file_id}")
      unless File.directory?(document_dir)
        res.status = 404
      else
        res.write view("pdf_view.html",
                       page_images: Dir.glob(File.join(document_dir, "document_*.jpg"))
                         .sort_by { |f| f.gsub(/[^\d]/, '').to_i }
                         .map { |f| f.gsub(Dir.pwd + '/static', '') },
                       pages:       parse_document_xml(File.join(document_dir, "document.xml"))
                         .xpath("//page"))
      end
      
    end

   
  end

  on post do
    on 'upload' do
      file_id = Digest::SHA1.hexdigest(Time.now.to_s)
      file_path = File.join(Dir.pwd, 'static', 'pdfs', file_id)
      FileUtils.mkdir(file_path)
      FileUtils.cp(req.params['file'][:tempfile].path, 
                   File.join(file_path, 'document.pdf'))

      Docsplit.extract_images(File.join(file_path, 'document.pdf'),
                              :size => '560x', :format => [:jpg], :output => file_path)

      if Settings::USE_JRUBY_ANALYZER
        run_jrubypdftohtml(File.join(file_path, 'document.pdf'), file_path)
      else
        run_pdftohtml(File.join(file_path, 'document.pdf'), file_path)
      end
      

      res.redirect "/pdf/#{file_id}"
    end
  end
  
end

