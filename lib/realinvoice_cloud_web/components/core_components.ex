defmodule RealinvoiceCloudWeb.CoreComponents do
  @moduledoc """
  App-level building blocks that sit alongside SaladUI.

  The component library for this app is [SaladUI](https://hexdocs.pm/salad_ui) —
  buttons, inputs, tables, cards, the sidebar and so on all come from there and
  are imported into every template by `RealinvoiceCloudWeb.html_helpers/0`. This
  module only keeps the few pieces SaladUI does not cover: flash notices, the JS
  show/hide transitions they use, and Ecto error translation.

  Everything here is styled from the design tokens in `assets/css/app.css`, so it
  follows the light/dark theme with the rest of the app.
  """
  use Phoenix.Component
  use Gettext, backend: RealinvoiceCloudWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
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
      class={[
        "fixed bottom-4 right-4 z-50 w-80 sm:w-96 cursor-pointer",
        "rounded-md border bg-popover px-4 py-3 text-sm shadow-lg",
        @kind == :info && "text-popover-foreground",
        @kind == :error && "border-destructive/40 text-destructive"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 font-semibold">
        <span :if={@kind == :info} class="hero-information-circle-mini size-4" />
        <span :if={@kind == :error} class="hero-exclamation-circle-mini size-4" />
        {@title}
      </p>
      <p class={["text-muted-foreground", @title && "mt-1"]}>{msg}</p>
      <p class="sr-only">{gettext("close")}</p>
    </div>
    """
  end

  @doc """
  A native `<select>`, styled to match SaladUI's input.

  SaladUI's own `select/1` builds its hidden input in JavaScript after mount, so
  its value is invisible to `phx-change` on first render and to
  `render_change/2` in tests. Filter forms need a value the server can read
  every time, so they use this instead; SaladUI's select stays the right choice
  for rich in-page selection that is driven by its own events.

  ## Examples

      <.select_input name="node" value={@filters["node"]} prompt="All nodes">
        <option :for={node <- @nodes} value={node} selected={@filters["node"] == node}>
          {node}
        </option>
      </.select_input>
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :prompt, :string, default: nil, doc: "a blank leading option, e.g. \"All nodes\""
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def select_input(assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      class={[
        "flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm",
        "focus-visible:outline-hidden focus-visible:border-ring focus-visible:ring-ring/50",
        "focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50",
        @class
      ]}
      {@rest}
    >
      <option :if={@prompt} value="" selected={@value in [nil, ""]}>{@prompt}</option>
      {render_slot(@inner_block)}
    </select>
    """
  end

  @doc """
  A centred icon + message block for screens that have nothing to show yet.

  SaladUI has no empty-state component, so this is a plain flat block built from
  the same tokens.

  ## Examples

      <.empty_state icon="hero-inbox" title="No data yet" message="Nothing here.">
        Optional longer explanation.
      </.empty_state>
  """
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  attr :message, :string, required: true
  slot :inner_block, doc: "optional supporting copy under the message"

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center px-6 py-24 text-center">
      <span class="mb-5 flex size-12 items-center justify-center rounded-full bg-muted text-muted-foreground">
        <span class={[@icon, "size-6 bg-muted-foreground"]} />
      </span>
      <h2 class="text-base font-semibold">{@title}</h2>
      <p class="mt-1.5 text-sm text-muted-foreground">{@message}</p>
      <p :if={@inner_block != []} class="mt-4 max-w-md text-sm leading-relaxed text-muted-foreground">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc """
  Label/value rows, hairline separated — the About/Account pane treatment.

  ## Examples

      <.detail_list>
        <:row label="Email">admin@example.com</:row>
        <:row label="Role">owner</:row>
      </.detail_list>
  """
  attr :class, :any, default: nil

  slot :row, doc: "one label/value pair" do
    attr :label, :string, required: true
  end

  def detail_list(assigns) do
    ~H"""
    <dl class={["divide-y divide-border border-y border-border", @class]}>
      <div
        :for={row <- @row}
        class="flex flex-col gap-1 py-3 sm:flex-row sm:items-baseline sm:gap-6"
      >
        <dt class="w-48 shrink-0 text-sm text-muted-foreground">{row.label}</dt>
        <dd class="min-w-0 text-sm">{render_slot(row)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  A flat section heading: a small label above a hairline rule.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil

  def section_heading(assigns) do
    ~H"""
    <div class={["mb-4", @class]}>
      <h2 class="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
        {@title}
      </h2>
      <p :if={@description} class="mt-1 text-sm text-muted-foreground">{@description}</p>
    </div>
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
      Gettext.dngettext(RealinvoiceCloudWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RealinvoiceCloudWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
