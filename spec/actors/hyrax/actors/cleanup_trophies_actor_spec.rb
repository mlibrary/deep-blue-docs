require 'rails_helper'

RSpec.describe Hyrax::Actors::CleanupTrophiesActor, skip: false do
  let(:ability) { ::Ability.new(depositor) }
  let(:env) { Hyrax::Actors::Environment.new(work, ability, attributes) }
  let(:terminator) { Hyrax::Actors::Terminator.new }
  let(:depositor) { create(:user) }
  let(:work) { create(:work) }
  let(:attributes) { {} }

  subject(:middleware) do
    stack = ActionDispatch::MiddlewareStack.new.tap do |middleware|
      middleware.use described_class
    end
    stack.build(terminator)
  end

  describe "#destroy" do
    subject { middleware.destroy(env) }

    let!(:trophy) { Trophy.create(user_id: depositor.id, work_id: work.id) }

    it 'removes all the trophies' do
      expect { middleware.destroy(env) }.to change { Trophy.where(work_id: work.id).count }.from(1).to(0)
    end
  end
end
