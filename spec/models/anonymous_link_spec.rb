require 'rails_helper'

RSpec.describe AnonymousLink do

  let(:file) { FileSet.new(id: 'abc123') }

  describe "default attributes" do
    let(:hash) { "sha2hash#{DateTime.current.to_f}" }
    let(:path) { '/foo/file/99999' }

    subject { described_class.new itemId: '99999', path: path }

    it "creates link" do
      expect(Digest::SHA2).to receive(:new).and_return(hash)
      expect(subject.downloadKey).to eq hash
      expect(subject.itemId).to eq '99999'
      expect(subject.path).to eq path
    end
  end

end
