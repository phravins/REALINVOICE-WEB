defmodule RealinvoiceCloudWeb.NodeLive.Index do
  @moduledoc """
  Registering and revoking the billing desks allowed to sync.

  Owner-only: a node's token is the credential that lets a machine write
  invoices into this account, so issuing one is not something staff do casually.

  A freshly issued token is shown once, on this page, and is never recoverable —
  the server keeps only its SHA-256. That is the whole point of hashing it, so
  there is deliberately no "show token again" anywhere.
  """
  use RealinvoiceCloudWeb, :live_view

  on_mount {RealinvoiceCloudWeb.UserAuth, :require_owner}

  alias RealinvoiceCloud.Nodes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Nodes")
     |> assign(:form, to_form(Nodes.change_node_registration()))
     |> assign(:registering?, false)
     # Held in memory for this one render only; never written down anywhere.
     |> assign(:issued_token, nil)
     |> assign(:issued_node, nil)
     |> load_nodes()}
  end

  defp load_nodes(socket) do
    nodes = Nodes.list_nodes()

    socket
    |> assign(:nodes, nodes)
    |> assign(:active_count, Enum.count(nodes, &(&1.status == "active")))
  end

  @impl true
  def handle_event("start_registration", _params, socket) do
    {:noreply,
     socket
     |> assign(:registering?, true)
     |> assign(:issued_token, nil)
     |> assign(:issued_node, nil)
     |> assign(:form, to_form(Nodes.change_node_registration()))}
  end

  def handle_event("cancel_registration", _params, socket) do
    {:noreply, assign(socket, registering?: false)}
  end

  def handle_event("validate", %{"node" => params}, socket) do
    changeset =
      Nodes.change_node_registration(%Nodes.Node{}, params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("register", %{"node" => params}, socket) do
    case Nodes.register_node(params) do
      {:ok, node, token} ->
        {:noreply,
         socket
         |> assign(:registering?, false)
         |> assign(:issued_node, node)
         |> assign(:issued_token, token)
         |> load_nodes()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, issued_token: nil, issued_node: nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    node = Nodes.get_node!(id)
    {:ok, _node} = Nodes.revoke_node(node)

    {:noreply,
     socket
     |> put_flash(:info, "#{node.name} can no longer sync. Its token stops working immediately.")
     |> load_nodes()}
  end

  def handle_event("reinstate", %{"id" => id}, socket) do
    node = Nodes.get_node!(id)
    {:ok, _node} = Nodes.reinstate_node(node)

    {:noreply,
     socket
     |> put_flash(:info, "#{node.name} can sync again with its existing token.")
     |> load_nodes()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active={:nodes}
      title="Nodes"
      subtitle="The billing desks allowed to sync into this account"
    >
      <:actions>
        <.button :if={!@registering?} size="sm" phx-click="start_registration">
          <.icon name="hero-plus" class="mr-1.5 size-4" /> Register new node
        </.button>
      </:actions>

      <div class="max-w-4xl space-y-10">
        <.issued_token_panel :if={@issued_token} node={@issued_node} token={@issued_token} />

        <.registration_form :if={@registering?} form={@form} />

        <section>
          <.section_heading
            title="Registered desks"
            description="A desk can only sync while it is active. Revoking takes effect on its very next request."
          />

          <div :if={@nodes != []} class="overflow-x-auto">
            <.table>
              <.table_header>
                <.table_row>
                  <.table_head>Name</.table_head>
                  <.table_head>Status</.table_head>
                  <.table_head>Last seen</.table_head>
                  <.table_head>Registered</.table_head>
                  <.table_head class="text-right">Actions</.table_head>
                </.table_row>
              </.table_header>
              <.table_body>
                <.table_row :for={node <- @nodes}>
                  <.table_cell class="font-medium">{node.name}</.table_cell>
                  <.table_cell>
                    <.badge variant={if node.status == "active", do: "secondary", else: "outline"}>
                      {node.status}
                    </.badge>
                  </.table_cell>
                  <.table_cell class="whitespace-nowrap">
                    <span :if={node.last_seen_at}>{datetime(node.last_seen_at)}</span>
                    <span :if={is_nil(node.last_seen_at)} class="text-muted-foreground">
                      never synced
                    </span>
                  </.table_cell>
                  <.table_cell class="whitespace-nowrap text-muted-foreground">
                    {datetime(node.inserted_at)}
                  </.table_cell>
                  <.table_cell class="text-right">
                    <.button
                      :if={node.status == "active"}
                      variant="ghost"
                      size="sm"
                      phx-click="revoke"
                      phx-value-id={node.id}
                      data-confirm={"Revoke #{node.name}? Its token stops working immediately."}
                    >
                      Revoke
                    </.button>
                    <.button
                      :if={node.status == "revoked"}
                      variant="ghost"
                      size="sm"
                      phx-click="reinstate"
                      phx-value-id={node.id}
                    >
                      Reinstate
                    </.button>
                  </.table_cell>
                </.table_row>
              </.table_body>
            </.table>
          </div>

          <.empty_state
            :if={@nodes == []}
            icon="hero-server-stack"
            title="No desks registered"
            message="Register a node to give a billing desk a sync token."
          >
            Until a desk is registered and holds a token, nothing can push data into
            this account — every ingest request is rejected.
          </.empty_state>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :node, :map, required: true
  attr :token, :string, required: true

  defp issued_token_panel(assigns) do
    ~H"""
    <section
      id="issued-token"
      class="rounded-md border border-primary/40 bg-accent px-5 py-4"
      phx-mounted={JS.focus_first()}
    >
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-sm font-semibold">{@node.name} is registered</h2>
          <p class="mt-1 text-sm text-muted-foreground">
            Copy this token into the desk's sync settings now. It is not stored and
            cannot be shown again — if it is lost, register the desk again.
          </p>
        </div>
        <.button variant="ghost" size="sm" phx-click="dismiss_token">Done</.button>
      </div>

      <p
        id="issued-token-value"
        class="mt-4 overflow-x-auto rounded border border-border bg-background px-3 py-2 font-mono text-sm select-all"
      >
        {@token}
      </p>
    </section>
    """
  end

  attr :form, :map, required: true

  defp registration_form(assigns) do
    ~H"""
    <section>
      <.section_heading
        title="Register a node"
        description="The name is what the desk reports as, and what its invoices are filed under — usually the till it runs on."
      />

      <.form
        for={@form}
        id="node-registration"
        phx-change="validate"
        phx-submit="register"
        class="flex flex-wrap items-start gap-3"
      >
        <.form_item class="min-w-64 flex-1">
          <.form_label field={@form[:name]}>Name</.form_label>
          <.form_control>
            <.input
              field={@form[:name]}
              type="text"
              placeholder="POS-03"
              autocomplete="off"
              phx-mounted={JS.focus()}
            />
          </.form_control>
          <.form_message field={@form[:name]} />
        </.form_item>

        <div class="flex gap-2 pt-7">
          <.button phx-disable-with="Registering…">Register</.button>
          <.button type="button" variant="ghost" phx-click="cancel_registration">Cancel</.button>
        </div>
      </.form>
    </section>
    """
  end
end
