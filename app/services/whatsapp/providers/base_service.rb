#######################################
# To create a whatsapp provider
# - Inherit this as the base class.
# - Implement `send_message` method in your child class.
# - Implement `send_template_message` method in your child class.
# - Implement `sync_templates` method in your child class.
# - Implement `validate_provider_config` method in your child class.
# - Use Childclass.new(whatsapp_channel: channel).perform.
######################################

class Whatsapp::Providers::BaseService
  # Supported MIME types per WhatsApp media category
  # Reference: https://developers.facebook.com/docs/whatsapp/cloud-api/reference/media#supported-media-types
  WHATSAPP_SUPPORTED_IMAGE_TYPES = %w[image/jpeg image/png].freeze
  WHATSAPP_SUPPORTED_AUDIO_TYPES = %w[audio/aac audio/mp4 audio/mpeg audio/amr audio/ogg audio/opus].freeze
  WHATSAPP_SUPPORTED_VIDEO_TYPES = %w[video/mp4 video/3gp video/3gpp].freeze
  WHATSAPP_SUPPORTED_STICKER_TYPES = %w[image/webp].freeze
  WHATSAPP_SUPPORTED_DOCUMENT_TYPES = %w[
    text/plain application/pdf
    application/vnd.ms-powerpoint application/msword application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  ].freeze

  WHATSAPP_ALL_SUPPORTED_TYPES = (
    WHATSAPP_SUPPORTED_IMAGE_TYPES +
    WHATSAPP_SUPPORTED_AUDIO_TYPES +
    WHATSAPP_SUPPORTED_VIDEO_TYPES +
    WHATSAPP_SUPPORTED_STICKER_TYPES +
    WHATSAPP_SUPPORTED_DOCUMENT_TYPES
  ).freeze

  pattr_initialize [:whatsapp_channel!]

  def send_message(_phone_number, _message)
    raise 'Overwrite this method in child class'
  end

  def send_template(_phone_number, _template_info, _message)
    raise 'Overwrite this method in child class'
  end

  def sync_template
    raise 'Overwrite this method in child class'
  end

  def validate_provider_config
    raise 'Overwrite this method in child class'
  end

  def error_message
    raise 'Overwrite this method in child class'
  end

  def process_response(response, message)
    parsed_response = response.parsed_response
    if response.success? && parsed_response['error'].blank?
      parsed_response['messages'].first['id']
    else
      handle_error(response, message)
      nil
    end
  end

  def handle_error(response, message)
    Rails.logger.error response.body
    return if message.blank?

    # https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes/#sample-response
    error_message = error_message(response)
    return if error_message.blank?

    message.external_error = error_message
    message.status = :failed
    message.save!
  end

  def create_buttons(items)
    buttons = []
    items.each do |item|
      button = { :type => 'reply', 'reply' => { 'id' => item['value'], 'title' => item['title'] } }
      buttons << button
    end
    buttons
  end

  def create_rows(items)
    rows = []
    items.each do |item|
      row = { 'id' => item['value'], 'title' => item['title'] }
      rows << row
    end
    rows
  end

  def create_payload(type, message_content, action)
    {
      'type': type,
      'body': {
        'text': message_content
      },
      'action': action
    }
  end

  def create_payload_based_on_items(message)
    if message.content_attributes['items'].length <= 3
      create_button_payload(message)
    else
      create_list_payload(message)
    end
  end

  def create_button_payload(message)
    buttons = create_buttons(message.content_attributes['items'])
    json_hash = { 'buttons' => buttons }
    create_payload('button', message.outgoing_content, JSON.generate(json_hash))
  end

  def create_list_payload(message)
    rows = create_rows(message.content_attributes['items'])
    section1 = { 'rows' => rows }
    sections = [section1]
    json_hash = { :button => I18n.t('conversations.messages.whatsapp.list_button_label'), 'sections' => sections }
    create_payload('list', message.outgoing_content, JSON.generate(json_hash))
  end

  # Validates that the attachment MIME type is supported by WhatsApp.
  # Returns true if valid, false if the message was marked as failed.
  def validate_whatsapp_attachment!(attachment, message)
    content_type = attachment.file&.content_type
    return true if content_type.present? && WHATSAPP_ALL_SUPPORTED_TYPES.include?(content_type)

    message.update!(
      status: :failed,
      external_error: I18n.t('errors.whatsapp.unsupported_media_type', content_type: content_type)
    )
    false
  end

  # Resolves the correct WhatsApp media type based on the actual file MIME type.
  # WhatsApp only supports specific MIME types for image/audio/video categories.
  # Unsupported MIME types (e.g. GIF, SVG, WAV, WebM, MOV) fall back to 'document'.
  def resolve_whatsapp_attachment_type(attachment)
    content_type = attachment.file&.content_type

    return 'document' if content_type.blank?

    if WHATSAPP_SUPPORTED_STICKER_TYPES.include?(content_type)
      'sticker'
    elsif WHATSAPP_SUPPORTED_IMAGE_TYPES.include?(content_type)
      'image'
    elsif WHATSAPP_SUPPORTED_AUDIO_TYPES.include?(content_type)
      'audio'
    elsif WHATSAPP_SUPPORTED_VIDEO_TYPES.include?(content_type)
      'video'
    else
      'document'
    end
  end
end
