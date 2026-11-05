defmodule ToreWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: ToreWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50 w-80 sm:w-96"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-[var(--r-lg)] border px-4 py-3 shadow-[var(--shadow-pop)]",
        @kind == :info && "bg-[var(--surface)] border-[color:var(--hairline)] text-[var(--text)]",
        @kind == :error && "bg-red-50 border-red-200 text-red-800"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 mt-0.5 text-[color:var(--accent)]"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 mt-0.5 text-red-500"
        />
        <div class="flex-1 min-w-0" style="font-size: var(--t-meta);">
          <p :if={@title} class="font-semibold mb-0.5">{@title}</p>
          <p>{msg}</p>
        </div>
        <button type="button" class="group shrink-0 cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-4 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def icon(%{name: "custom-prep"} = assigns) do
    ~H"""
    <img src="/images/prep_icon.svg" class={@class} aria-hidden="true" />
    """
  end

  def icon(%{name: "custom-pantry"} = assigns) do
    ~H"""
    <img src="/images/pantry_icon.svg" class={@class} aria-hidden="true" />
    """
  end

  def icon(%{name: "nav-" <> icon_name} = assigns) do
    assigns = assign(assigns, :src, "/images/nav_#{icon_name}.svg")

    ~H"""
    <img src={@src} class={["nav-icon", @class]} aria-hidden="true" />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ToreWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ToreWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # ----------------------------------------------------------------------
  # Design system primitives — see SPEC_FEAT_ui-redesign.md
  # ----------------------------------------------------------------------

  @doc ~S"""
  Page container.

      <.page><.page_header title="Week" /></.page>
  """
  attr :max_width, :atom, values: [:sm, :md, :lg, :xl], default: :lg
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div class={["mx-auto w-full", page_max_class(@max_width)]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp page_max_class(:sm), do: "max-w-md"
  defp page_max_class(:md), do: "max-w-2xl"
  defp page_max_class(:lg), do: "max-w-4xl"
  defp page_max_class(:xl), do: "max-w-6xl"

  @doc ~S"""
  Page header with display title, optional subtitle, and right-aligned actions slot.

      <.page_header title="Week" subtitle="Apr 27 — May 3, 2026">
        <:actions><.button>Generate plan</.button></:actions>
      </.page_header>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :centered, :boolean, default: false
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-4 mb-6",
      @centered && "justify-center text-center",
      !@centered && "justify-between"
    ]}>
      <div>
        <h1
          class="font-semibold tracking-tight text-[var(--text)]"
          style="font-size: var(--t-h1); line-height: 1.2;"
        >
          {@title}
        </h1>
        <p :if={@subtitle} class="mt-0.5 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
          {@subtitle}
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2 shrink-0">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc ~S"""
  Card surface — white, rounded-2xl, soft shadow + 1px border.
  Default container for screens in the draft-ui design.

      <.card>…</.card>
      <.card padded={false}>…</.card>
  """
  attr :padded, :boolean, default: true
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class={[
        "bg-[var(--surface)] border border-[color:var(--border)] rounded-[var(--r-xl)]",
        "shadow-[var(--shadow-card)]",
        @padded && "p-5 md:p-6",
        @class
      ]}
      style="--shadow-card: 0 1px 2px rgba(17,24,39,0.04), 0 1px 3px rgba(17,24,39,0.05);"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc ~S"""
  Section block with optional micro-label title.

      <.section title="Produce">…</.section>
  """
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class="mb-6">
      <h2
        :if={@title}
        class="mb-3 text-[color:var(--text)]"
        style="font-size: var(--t-h2); font-weight: 600;"
      >
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc ~S"""
  Flat list row.

      <.row>
        <:leading><img … /></:leading>
        Roast chicken
        <:trailing><.chip>6 servings</.chip></:trailing>
      </.row>
  """
  attr :clickable, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-id href)
  slot :leading
  slot :trailing
  slot :inner_block, required: true

  def row(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-3 px-4 min-h-[var(--tap-min)] py-3 border-b border-[color:var(--hairline)] last:border-b-0",
        @clickable &&
          "cursor-pointer hover:bg-[color:var(--accent-soft)]/40 -mx-4 rounded-[var(--r-md)]"
      ]}
      {@rest}
    >
      <div :if={@leading != []} class="shrink-0">{render_slot(@leading)}</div>
      <div class="flex-1 min-w-0 text-[var(--text)]" style="font-size: var(--t-body);">
        {render_slot(@inner_block)}
      </div>
      <div :if={@trailing != []} class="shrink-0">{render_slot(@trailing)}</div>
    </div>
    """
  end

  @doc ~S"""
  Button. Variant: :primary (default), :ghost, :danger. Size: :md, :lg.

      <.button>Save</.button>
      <.button variant={:ghost} size={:lg} phx-click="cancel">Cancel</.button>
  """
  attr :variant, :atom, values: [:primary, :secondary, :ghost, :danger], default: :primary
  attr :size, :atom, values: [:md, :lg, :xl], default: :md
  attr :type, :string, default: "button"
  attr :full, :boolean, default: false

  attr :rest, :global,
    include: ~w(phx-click phx-value-id href disabled form name value phx-disable-with)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center gap-2 font-semibold rounded-[var(--r-lg)] transition-colors disabled:opacity-40 disabled:pointer-events-none",
        button_size_class(@size),
        button_variant_class(@variant),
        @full && "w-full"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_size_class(:md), do: "h-11 px-5 text-[length:var(--t-body)]"
  defp button_size_class(:lg), do: "h-12 px-6 text-[length:var(--t-body)]"
  defp button_size_class(:xl), do: "h-14 px-7 text-[length:var(--t-h2)]"

  defp button_variant_class(:primary),
    do:
      "bg-[color:var(--accent)] text-white hover:bg-[color:var(--accent-hover)] shadow-[0_1px_2px_rgba(17,24,39,0.06)]"

  defp button_variant_class(:secondary),
    do:
      "bg-[var(--surface)] text-[var(--text)] border border-[color:var(--border)] hover:border-[color:var(--subtle)]"

  defp button_variant_class(:ghost),
    do: "bg-transparent text-[color:var(--muted)] hover:text-[var(--text)]"

  defp button_variant_class(:danger),
    do: "bg-transparent text-[color:var(--danger)] hover:bg-red-50"

  @doc ~S"""
  Square 44px icon button.

      <.icon_button icon="hero-x-mark" label="Close" phx-click="close" />
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global, include: ~w(phx-click phx-value-id href)

  def icon_button(assigns) do
    ~H"""
    <button
      type="button"
      class="inline-flex items-center justify-center size-11 rounded-[var(--r-md)] text-[color:var(--muted)] hover:bg-[color:var(--border)] hover:text-[var(--text)]"
      {@rest}
    >
      <.icon name={@icon} class="size-5" />
      <span class="sr-only">{@label}</span>
    </button>
    """
  end

  @doc ~S"""
  Underline-style text input.

      <.field name="name" label="Name" value={@name} />
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :type, :string, default: "text"
  attr :label, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(required disabled autocomplete inputmode pattern step min)

  def field(assigns) do
    assigns = assign_new(assigns, :id, fn -> assigns.name end)

    ~H"""
    <label for={@id} class="block">
      <span
        :if={@label}
        class="block mb-1.5 text-[color:var(--muted)]"
        style="font-size: var(--t-meta); font-weight: 500;"
      >
        {@label}
      </span>
      <input
        id={@id}
        name={@name}
        type={@type}
        value={@value}
        placeholder={@placeholder}
        class={[
          "w-full h-11 px-3.5 bg-[var(--surface)] rounded-[var(--r-lg)] border text-[var(--text)] placeholder:text-[color:var(--subtle)] focus:outline-none transition-colors",
          @errors == [] && "border-[color:var(--border)] focus:border-[color:var(--accent)]",
          @errors != [] && "border-[color:var(--danger)]"
        ]}
        style="font-size: var(--t-body);"
        {@rest}
      />
      <p
        :for={err <- @errors}
        class="mt-1 text-[color:var(--danger)]"
        style="font-size: var(--t-meta);"
      >
        {err}
      </p>
    </label>
    """
  end

  @doc ~S"""
  Square 24px checkbox. Use as a button (not a real form input).

      <.checkbox checked={item.checked} phx-click="toggle" phx-value-id={item.id} />
  """
  attr :checked, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-item_id)

  def checkbox(assigns) do
    ~H"""
    <button
      type="button"
      role="checkbox"
      aria-checked={to_string(@checked)}
      class={[
        "inline-flex items-center justify-center size-6 rounded-[var(--r-sm)] border-2 transition-colors",
        @checked && "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
        !@checked && "bg-transparent border-[color:var(--subtle)] hover:border-[color:var(--accent)]"
      ]}
      {@rest}
    >
      <.icon :if={@checked} name="hero-check-mini" class="size-4" />
    </button>
    """
  end

  @doc ~S"""
  Pill chip. Tone: :neutral (default), :accent, :muted.

      <.chip tone={:accent}>Today</.chip>
  """
  attr :tone, :atom, values: [:neutral, :accent, :muted, :warn], default: :accent
  attr :icon, :string, default: nil
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 px-2.5 h-7 rounded-[var(--r-pill)]",
        chip_tone_class(@tone)
      ]}
      style="font-size: var(--t-meta); font-weight: 500;"
    >
      <.icon :if={@icon} name={@icon} class="size-3.5" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_tone_class(:neutral), do: "bg-[color:var(--hairline)] text-[var(--text)]"

  defp chip_tone_class(:accent),
    do: "bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)]"

  defp chip_tone_class(:warn), do: "bg-[color:var(--warn-soft)] text-[#9a4a13]"
  defp chip_tone_class(:muted), do: "bg-transparent text-[color:var(--muted)]"

  @doc ~S"""
  Tab strip with underline-on-active (Ingredients · Instructions · Notes).
  Pure stateless render — caller wires up phx-click and `active`.

      <.tabs items={[%{id: "ing", label: "Ingredients"}, ...]} active="ing" event="set_tab" />
  """
  attr :items, :list, required: true
  attr :active, :string, required: true
  attr :event, :string, default: "set_tab"
  attr :param, :string, default: "tab"

  def tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-1 border-b border-[color:var(--border)]">
      <button
        :for={item <- @items}
        type="button"
        phx-click={@event}
        phx-value-tab={item.id}
        class={[
          "h-11 px-4 -mb-px border-b-2 transition-colors",
          item.id == @active && "text-[var(--text)] border-[color:var(--accent)]",
          item.id != @active &&
            "text-[color:var(--muted)] border-transparent hover:text-[var(--text)]"
        ]}
        style="font-size: var(--t-body); font-weight: 500;"
      >
        {item.label}
      </button>
    </div>
    """
  end

  @doc ~S"""
  Photo + title + meta tile, used in recipe grids and weekly planner.

      <.tile image={@recipe.image_url} title={@recipe.title}>
        <:meta><.icon name="hero-clock" class="size-4" /> 30 min</:meta>
      </.tile>
  """
  attr :image, :string, default: nil
  attr :title, :string, required: true
  attr :rest, :global, include: ~w(phx-click phx-value-id href)
  slot :meta
  slot :overlay

  def tile(assigns) do
    ~H"""
    <button
      type="button"
      class="group block w-full text-left"
      {@rest}
    >
      <div class="relative aspect-[4/3] w-full overflow-hidden rounded-[var(--r-xl)] bg-[color:var(--hairline)]">
        <img
          :if={@image}
          src={@image}
          alt=""
          class="h-full w-full object-cover transition-transform group-hover:scale-[1.02]"
        />
        <div
          :if={!@image}
          class="h-full w-full flex items-center justify-center text-[color:var(--subtle)]"
        >
          <.icon name="hero-photo" class="size-8" />
        </div>
        <div :if={@overlay != []} class="absolute inset-0">{render_slot(@overlay)}</div>
      </div>
      <div class="mt-3">
        <p class="font-semibold text-[var(--text)]" style="font-size: var(--t-body);">{@title}</p>
        <div
          :if={@meta != []}
          class="mt-1 flex items-center gap-3 text-[color:var(--muted)]"
          style="font-size: var(--t-meta);"
        >
          {render_slot(@meta)}
        </div>
      </div>
    </button>
    """
  end

  @doc ~S"""
  Empty-state line.

      <.empty message="No items" />
  """
  attr :message, :string, required: true

  def empty(assigns) do
    ~H"""
    <p class="text-center py-8 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
      {@message}
    </p>
    """
  end

  @doc ~S"""
  Right-side slide-over drawer.

      <.drawer id="swap" show={@open} on_close={JS.push("close")}>…</.drawer>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_close, JS, default: %JS{}
  slot :inner_block, required: true

  def drawer(assigns) do
    ~H"""
    <div
      id={@id}
      class={["fixed inset-0 z-50", !@show && "hidden"]}
      aria-hidden={to_string(!@show)}
    >
      <div class="absolute inset-0 bg-black/30" phx-click={@on_close}></div>
      <aside class="absolute right-0 top-0 h-full w-full max-w-[420px] bg-[var(--surface)] shadow-xl overflow-y-auto">
        <div class="flex justify-end p-2 border-b border-[color:var(--border)]">
          <.icon_button icon="hero-x-mark" label={gettext("Close")} phx-click={@on_close} />
        </div>
        <div class="p-4">{render_slot(@inner_block)}</div>
      </aside>
    </div>
    """
  end
end
