require 'acts-as-taggable-on'
require 'acts_as_list'

module Alchemy
  class Element < ActiveRecord::Base
    include Logger

    FORBIDDEN_DEFINITION_ATTRIBUTES = %w(contents available_contents amount picture_gallery taggable hint)
    SKIPPED_ATTRIBUTES_ON_COPY = %w(id position folded created_at updated_at creator_id updater_id cached_tag_list)

    acts_as_taggable

    attr_accessible(
      :cell_id,
      :create_contents_after_create,
      :folded,
      :name,
      :page_id,
      :public,
      :tag_list,
      :unique
    )

    # All Elements inside a cell are a list. All Elements not in cell are in the cell_id.nil list.
    acts_as_list :scope => [:page_id, :cell_id]
    stampable stamper_class_name: Alchemy.user_class_name

    has_many :contents, :order => :position, :dependent => :destroy
    belongs_to :cell
    belongs_to :page, touch: true
    has_and_belongs_to_many :to_be_sweeped_pages, :class_name => 'Alchemy::Page', :uniq => true, :join_table => 'alchemy_elements_alchemy_pages'

    validates_uniqueness_of :position, :scope => [:page_id, :cell_id], :if => lambda { |e| e.position != nil }
    validates_presence_of :name, :on => :create
    validates_format_of :name, :on => :create, :with => /\A[a-z0-9_-]+\z/

    attr_accessor :create_contents_after_create

    after_create :create_contents, :unless => proc { |e| e.create_contents_after_create == false }

    scope :trashed, where(:position => nil).order('updated_at DESC')
    scope :not_trashed, where(Element.arel_table[:position].not_eq(nil))
    scope :published, where(:public => true)
    scope :not_restricted, joins(:page).where("alchemy_pages" => {:restricted => false})
    scope :available, published.not_trashed
    scope :named, lambda { |names| where(:name => names) }
    scope :excluded, lambda { |names| where(arel_table[:name].not_in(names)) }
    scope :not_in_cell, where(:cell_id => nil)
    scope :in_cell, where("#{self.table_name}.cell_id IS NOT NULL")
    # Scope for only the elements from Alchemy::Site.current
    scope :from_current_site, lambda { where(:alchemy_languages => {site_id: Site.current || Site.default}).joins(:page => :language) }
    # TODO: add this as default_scope
    #default_scope { from_current_site }

    # Concerns
    include Definitions
    include Presenters

    # class methods
    class << self

      # Builds a new element as described in +/config/alchemy/elements.yml+
      def new_from_scratch(attributes)
        attributes = attributes.dup.symbolize_keys
        return new if attributes[:name].blank?
        return nil if definitions.blank?
        # clean the name from cell name
        attributes[:name] = attributes[:name].split('#').first
        if element_scratch = definitions.detect { |el| el['name'] == attributes[:name] }
          new(element_scratch.merge(attributes).except(*FORBIDDEN_DEFINITION_ATTRIBUTES))
        else
          raise ElementDefinitionError, "Element definition for #{attributes[:name]} not found. Please check your elements.yml"
        end
      end

      # Builds a new element as described in +/config/alchemy/elements.yml+ and saves it
      def create_from_scratch(attributes)
        element = new_from_scratch(attributes)
        element.save if element
        return element
      end

      # This methods does a copy of source and all depending contents and all of their depending essences.
      #
      # == Options
      #
      # You can pass a differences Hash as second option to update attributes for the copy.
      #
      # == Example
      #
      #   @copy = Alchemy::Element.copy(@element, {:public => false})
      #   @copy.public? # => false
      #
      def copy(source, differences = {})
        source.attributes.stringify_keys!
        differences.stringify_keys!
        attributes = source.attributes.except(*SKIPPED_ATTRIBUTES_ON_COPY).merge(differences)
        element = self.create!(attributes.merge(:create_contents_after_create => false))
        element.tag_list = source.tag_list
        source.contents.each do |content|
          new_content = Content.copy(content, :element_id => element.id)
          new_content.move_to_bottom
        end
        element
      end

      def all_from_clipboard(clipboard)
        return [] if clipboard.nil?
        find_all_by_id(clipboard.collect { |e| e[:id] })
      end

      # All elements in clipboard that could be placed on page
      #
      def all_from_clipboard_for_page(clipboard, page)
        return [] if clipboard.nil? || page.nil?
        all_from_clipboard(clipboard).select { |ce|
          page.available_element_names.include?(ce.name)
        }
      end

    end

    # Returns next public element from same page.
    #
    # Pass an element name to get next of this kind.
    #
    def next(name = nil)
      previous_or_next('>', name)
    end

    # Returns previous public element from same page.
    #
    # Pass an element name to get previous of this kind.
    #
    def prev(name = nil)
      previous_or_next('<', name)
    end

    # Stores the page into `to_be_sweeped_pages` (Pages that have to be sweeped after updating element).
    def store_page(page)
      return true if page.nil?
      unless self.to_be_sweeped_pages.include? page
        self.to_be_sweeped_pages << page
        self.save
      end
    end

    # Trashing an element means nullifying its position, folding and unpublishing it.
    def trash
      self.update_column(:public, false)
      self.update_column(:folded, true)
      self.remove_from_list
    end

    def trashed?
      self.position.nil?
    end

    def content_by_name(name)
      self.contents.find_by_name(name)
    end

    def content_by_type(essence_type)
      self.contents.find_by_essence_type(Content.normalize_essence_type(essence_type))
    end

    def all_contents_by_name(name)
      self.contents.where(:name => name)
    end

    def all_contents_by_type(essence_type)
      self.contents.where(:essence_type => Content.normalize_essence_type(essence_type))
    end

    # Returns the content that is marked as rss title.
    #
    # Mark a content as rss title in your +elements.yml+ file:
    #
    #   - name: news
    #     contents:
    #     - name: headline
    #       type: EssenceText
    #       rss_title: true
    #
    def content_for_rss_title
      rss_title = content_descriptions.detect { |c| c['rss_title'] }
      contents.find_by_name(rss_title['name'])
    end

    # Returns the content that is marked as rss definition.
    #
    # Mark a content as rss definition in your +elements.yml+ file:
    #
    #   - name: news
    #     contents:
    #     - name: body
    #       type: EssenceRichtext
    #       rss_description: true
    #
    def content_for_rss_description
      rss_title = content_descriptions.detect { |c| c['rss_description'] }
      contents.find_by_name(rss_title['name'])
    end

    # Returns the array with the hashes for all element contents in the elements.yml file
    def content_descriptions
      return nil if definition.blank?
      definition['contents']
    end

    # Returns the definition for given content_name
    def content_description_for(content_name)
      if content_descriptions.blank?
        log_warning "Element #{self.name} is missing the content definition for #{content_name}"
        return nil
      else
        content_descriptions.detect { |d| d['name'] == content_name }
      end
    end

    # Returns the definition for given content_name inside the available_contents
    def available_content_description_for(content_name)
      return nil if available_contents.blank?
      available_contents.detect { |d| d['name'] == content_name }
    end

    # returns the collection of available essence_types that can be created for this element depending on its description in elements.yml
    def available_contents
      definition['available_contents']
    end

    # Returns the contents ingredient for passed content name.
    def ingredient(name)
      content = content_by_name(name)
      return nil if content.blank?
      content.ingredient
    end

    def has_ingredient?(name)
      self.ingredient(name).present?
    end

    def save_contents(contents_attributes)
      return true if contents_attributes.nil?
      contents.each do |content|
        unless content.update_essence(contents_attributes["content_#{content.id}"])
          errors.add(:base, :essence_validation_failed)
        end
      end
      return errors.blank?
    end

    def essences
      return [] if contents.blank?
      contents.collect(&:essence)
    end

    # Returns all essence_errors in the format:
    #
    #   {
    #     essence.content.name => [error_message_for_validation_1, error_message_for_validation_2]
    #   }
    #
    # Get translated error messages with Element#essence_error_messages
    #
    def essence_errors
      essence_errors = {}
      essences.each do |essence|
        unless essence.errors.blank?
          essence_errors[essence.content.name] = essence.validation_errors
        end
      end
      essence_errors
    end

    # Essence validation errors
    #
    # == Error messages are translated via I18n
    #
    # Inside your translation file add translations like:
    #
    #   alchemy:
    #     content_validations:
    #       name_of_the_element:
    #         name_of_the_content:
    #           validation_error_type: Error Message
    #
    # NOTE: +validation_error_type+ has to be one of:
    #
    #   * blank
    #   * taken
    #   * invalid
    #
    # === Example:
    #
    #   de:
    #     alchemy:
    #       content_validations:
    #         contactform:
    #           email:
    #             invalid: 'Die Email hat nicht das richtige Format'
    #
    #
    # == Error message translation fallbacks
    #
    # In order to not translate every single content for every element you can provide default error messages per content name:
    #
    # === Example
    #
    #   en:
    #     alchemy:
    #       content_validations:
    #         fields:
    #           email:
    #             invalid: E-Mail has wrong format
    #             blank: E-Mail can't be blank
    #
    # And even further you can provide general field agnostic error messages:
    #
    # === Example
    #
    #   en:
    #     alchemy:
    #       content_validations:
    #         errors:
    #           invalid: %{field} has wrong format
    #           blank: %{field} can't be blank
    #
    def essence_error_messages
      messages = []
      essence_errors.each do |content_name, errors|
        errors.each do |error|
          messages << I18n.t(
            "#{name}.#{content_name}.#{error}",
            :scope => :content_validations,
            :default => [
              "fields.#{content_name}.#{error}".to_sym,
              "errors.#{error}".to_sym
            ],
            :field => Content.translated_label_for(content_name)
          )
        end
      end
      messages
    end

    def contents_with_errors
      contents.select(&:essence_validation_failed?)
    end

    def has_validations?
      !contents.detect(&:has_validations?).blank?
    end

    def rtf_contents
      contents.essence_richtexts.all
    end
    alias_method :richtext_contents, :rtf_contents

    # Returns an array of all EssenceRichtext contents ids
    #
    def richtext_contents_ids
      contents.essence_richtexts.pluck('alchemy_contents.id')
    end

    # The names of all cells from given page this element could be placed in.
    def belonging_cellnames(page)
      cellnames = page.cells.select { |c| c.available_elements.include?(self.name) }.collect(&:name).flatten.uniq
      if cellnames.blank? || !page.has_cells?
        ['for_other_elements']
      else
        cellnames
      end
    end

    # returns true if the page this element is displayed on is restricted?
    def restricted?
      page.restricted?
    end

    # Returns true if the definition of this element has a taggable true value.
    def taggable?
      definition['taggable'] == true
    end

    def to_partial_path
      "alchemy/elements/#{name}_view"
    end

    # Returns the hint for this element
    #
    # To add a hint to an element either pass +hint: true+ to the element definition in its element.yml
    #
    # Then the hint itself is placed in the locale yml files.
    #
    # Alternativly you can pass the hint itself to the hint key.
    #
    # == Locale Example:
    #
    #   # elements.yml
    #   - name: headline
    #     hint: true
    #
    #   # config/locales/de.yml
    #     de:
    #       element_hints:
    #         headline: Lorem ipsum
    #
    # == Hint Key Example:
    #
    #   - name: headline
    #     hint: "Lorem ipsum"
    #
    # @return String
    #
    def hint
      hint = definition['hint']
      if hint == true
        I18n.t(name, scope: :element_hints)
      else
        hint
      end
    end

    # Returns true if the element has a hint
    def has_hint?
      hint.present?
    end

  private

    # creates the contents for this element as described in the elements.yml
    def create_contents
      contents = []
      if definition["contents"].blank?
        log_warning "Could not find any content descriptions for element: #{self.name}"
      else
        definition["contents"].each do |content_hash|
          contents << Content.create_from_scratch(self, content_hash.symbolize_keys)
        end
      end
    end

    # Returns previous or next public element from same page.
    #
    # @param [String]
    #   Pass '>' or '<' to find next or previous public element.
    # @param [String]
    #   Pass an element name to get previous of this kind.
    #
    def previous_or_next(dir, name = nil)
      elements = page.elements.published.where("#{self.class.table_name}.position #{dir} #{position}")
      elements = elements.named(name) if name.present?
      elements.reorder("position #{dir == '>' ? 'ASC' : 'DESC'}").limit(1).first
    end

  end
end
