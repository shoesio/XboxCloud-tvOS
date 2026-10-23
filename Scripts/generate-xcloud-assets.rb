#!/usr/bin/env ruby
require 'fileutils'
require 'json'
require 'base64'
root = File.expand_path('..', __dir__)
artwork = File.join(root, 'Forza6/Artwork/XCloud')
catalog = File.join(root, 'Forza6/Resources/Assets.xcassets')
brand = File.join(catalog, 'Xbox Cloud Icon.brandassets')
info = {author: 'xcode', version: 1}
def json(path, object)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(object))
end
def render(source, destination, svg)
  FileUtils.mkdir_p(File.dirname(destination))
  File.write(source, svg)
  abort "Rendering failed: #{destination}" unless system('rsvg-convert', source, '-o', destination)
end
logo = Base64.strict_encode64(File.binread(File.join(artwork, 'xbox-mark.svg')))
def layout(w, h, logo, show_logo: true)
  size = [w * 0.7, h * 0.5833333333].min
  mark = show_logo ? "<image x='#{(w-size)/2}' y='#{(h-size)/2}' width='#{size}' height='#{size}' preserveAspectRatio='xMidYMid meet' xlink:href='data:image/svg+xml;base64,#{logo}'/>" : ''
  "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' width='#{w}' height='#{h}' viewBox='0 0 #{w} #{h}'><defs><linearGradient id='bg' x2='1' y2='1'><stop stop-color='#138c13'/><stop offset='0.5' stop-color='#107c10'/><stop offset='1' stop-color='#075b07'/></linearGradient></defs><rect width='#{w}' height='#{h}' fill='url(#bg)'/>#{mark}</svg>"
end
json(File.join(catalog, 'Contents.json'), {info: info})
assets = []
[['App Icon', [[400,240,'1x'],[800,480,'2x']]], ['App Store Icon', [[1280,768,'1x']]]].each do |name, sizes|
  stack = File.join(brand, "#{name}.imagestack")
  json(File.join(stack, 'Contents.json'), {layers: [{filename: 'Artwork.imagestacklayer'}, {filename: 'Background.imagestacklayer'}], info: info})
  ['Artwork', 'Background'].each do |layer_name|
    layer = File.join(stack, "#{layer_name}.imagestacklayer")
    json(File.join(layer, 'Contents.json'), {info: info})
    images = sizes.map do |w,h,scale|
      filename = "icon_#{w}x#{h}.png"
      render(File.join(artwork, "#{layer_name.downcase}_#{w}x#{h}.svg"), File.join(layer, 'Content.imageset', filename), layout(w,h,logo,show_logo: layer_name == 'Artwork'))
      {filename: filename, idiom: 'tv', scale: scale}
    end
    json(File.join(layer, 'Content.imageset/Contents.json'), {images: images, info: info})
  end
  w,h,_ = sizes.first
  assets << {filename: "#{name}.imagestack", idiom: 'tv', role: 'primary-app-icon', size: "#{w}x#{h}"}
end
[['Top Shelf',1920,720,'top-shelf-image'],['Top Shelf Wide',2320,720,'top-shelf-image-wide']].each do |name,w,h,role|
  dir = File.join(brand, "#{name}.imageset")
  render(File.join(artwork, "#{name.gsub(' ','-')}.svg"), File.join(dir, 'banner.png'), layout(w,h,logo))
  json(File.join(dir, 'Contents.json'), {images: [{filename: 'banner.png', idiom: 'tv', scale: '1x'}], info: info})
  assets << {filename: "#{name}.imageset", idiom: 'tv', role: role, size: "#{w}x#{h}"}
end
json(File.join(brand, 'Contents.json'), {assets: assets, info: info})
loading = File.join(catalog, 'XCloudLoading.imageset')
render(File.join(artwork, 'loading.svg'), File.join(loading, 'banner.png'), layout(1920,1080,logo))
json(File.join(loading, 'Contents.json'), {images: [{filename: 'banner.png', idiom: 'universal'}], info: info})
puts 'Xbox Cloud assets generated.'
