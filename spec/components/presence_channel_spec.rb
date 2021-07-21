# frozen_string_literal: true

require 'rails_helper'
require 'presence_channel'

describe PresenceChannel do
  it "can perform basic channel functionality" do
    # 10ms timeout for testing
    channel1 = PresenceChannel.new("test")
    channel2 = PresenceChannel.new("test")
    channel3 = PresenceChannel.new("test")

    channel1.clear

    expect(channel3.user_ids).to eq([])

    channel1.enter(user_id: 1, client_id: 1)
    channel2.enter(user_id: 1, client_id: 2)

    expect(channel3.user_ids).to eq([1])
    expect(channel3.count).to eq(1)

    channel1.leave(user_id: 1, client_id: 2)

    expect(channel3.user_ids).to eq([1])
    expect(channel3.count).to eq(1)

    channel2.leave(user_id: 1, client_id: 1)

    expect(channel3.user_ids).to eq([])
    expect(channel3.count).to eq(0)
  end

  it "can automatically expire users" do

    channel = PresenceChannel.new("test")
    channel.clear

    channel.enter(user_id: 1)
    channel.enter(user_id: 1, client_id: 77)

    expect(channel.count).to eq(1)

    freeze_time Time.zone.now + 1 + PresenceChannel::DEFAULT_TIMEOUT

    expect(channel.count).to eq(0)
  end

  it "correctly sends messages to message bus" do
    channel = PresenceChannel.new("test")
    channel.clear

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.enter(user_id: 1, client_id: "a")
    end

    expect(messages.length).to eq(1)
    expected = {
      "type" => "enter",
      "user_id" => 1,
    }
    expect(messages[0].data).to eq(expected)

    freeze_time Time.zone.now + 1 + PresenceChannel::DEFAULT_TIMEOUT

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.auto_leave
    end

    expect(messages.length).to eq(1)
    expected = {
      "type" => "leave",
      "user_id" => 1,
    }
    expect(messages[0].data).to eq(expected)
  end

end
