# frozen_string_literal: true
# Generated by the protocol buffer compiler.  DO NOT EDIT!
# source: modification_tag.proto

require 'google/protobuf'


descriptor_data = "\n\x16modification_tag.proto\x12\x10\x64iego.bbs.models\"/\n\x0fModificationTag\x12\r\n\x05\x65poch\x18\x01 \x01(\t\x12\r\n\x05index\x18\x02 \x01(\rb\x06proto3"

pool = Google::Protobuf::DescriptorPool.generated_pool
pool.add_serialized_file(descriptor_data)

module Diego
  module Bbs
    module Models
      ModificationTag = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("diego.bbs.models.ModificationTag").msgclass
    end
  end
end
