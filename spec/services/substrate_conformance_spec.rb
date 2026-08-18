# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SubstrateConformance do
  let(:dir) { Dir.mktmpdir('substrate-') }
  after { FileUtils.rm_rf(dir) }

  def report
    described_class.call(path: dir)
  end

  def check(result, id)
    result[:checks].find { |c| c.id == id }
  end

  it 'passes a local filesystem, and covers all eight requirements' do
    result = report

    expect(result[:ok]).to be(true)
    expect(result[:checks].map(&:id)).to eq([1, 2, 3, 4, 5, 6, 7, 8])
    expect(result[:checks].select(&:required)).to all(satisfy(&:ok))
  end

  it 'records requirement 7 as one Atlas does not impose' do
    seven = check(report, 7)

    expect(seven.required).to be(false)
    expect(seven.detail).to eq('not required')
  end

  # Mountpoint for Amazon S3 refuses directory rename on any bucket type, and
  # file rename anywhere outside S3 Express One Zone. Both are EPERM.
  it 'disqualifies a substrate that refuses rename' do
    allow(File).to receive(:rename).and_raise(Errno::EPERM)

    result = report

    expect(result[:ok]).to be(false)
    expect(result[:checks].reject(&:ok).map(&:id)).to include(1, 2)
    expect(check(result, 1).detail).to match(/EPERM/)
  end

  it 'disqualifies a substrate that cannot fsync a directory' do
    # The directory fsync is the one-argument File.open; the file fsync passes a
    # mode as well, so matching on arity isolates the directory case.
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(a_string_matching(/substrate-check/))
                                 .and_raise(Errno::EINVAL)

    result = report

    expect(check(result, 4).ok).to be(false)
    expect(check(result, 4).detail).to match(/EINVAL/)
    expect(result[:ok]).to be(false)
  end

  it 'still gives a verdict on a substrate it cannot write to at all' do
    allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EROFS)

    result = report

    expect(result[:ok]).to be(false)
    expect(result[:checks].select(&:required)).to all(satisfy { |c| !c.ok })
    expect(check(result, 4).detail).to match(/EROFS/)
    expect(check(result, 7).ok).to be(true)
  end

  it 'leaves nothing behind in the substrate' do
    report

    expect(Pathname.new(dir).children).to eq([])
  end

  it 'refuses a path that is not a directory' do
    expect { described_class.call(path: File.join(dir, 'absent')) }
      .to raise_error(ArgumentError, /not a directory/)
  end

  it 'checks the filenames the sanitiser can actually emit' do
    # Coupling the check to the sanitiser's output domain is the point: a
    # substrate only has to accept what Atlas can produce.
    expect(described_class::SANITISED_NAMES).to include(a_string_matching(/\A\.\w/))
    expect(described_class::SANITISED_NAMES.map(&:bytesize).max).to eq(200)
    expect(check(report, 8).ok).to be(true)
  end
end
