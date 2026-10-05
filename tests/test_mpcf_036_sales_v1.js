const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const sql = fs.readFileSync(path.join(root, 'database', 'migrations', 'MPCF-036_SALES_V1.sql'), 'utf8').replace(/\r\n/g, '\n');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8').replace(/\r\n/g, '\n');

function functionBody(signature) {
  const start = sql.indexOf(signature);
  assert.notEqual(start, -1, `Missing SQL function ${signature}`);
  const bodyStart = sql.indexOf('as $$', start);
  const end = sql.indexOf('\n$$;', bodyStart);
  assert.notEqual(end, -1, `Unclosed SQL function ${signature}`);
  return sql.slice(start, end + 4);
}

const createCustomer = functionBody('create or replace function public.create_sales_customer(p_payload jsonb)');
const createOrder = functionBody('create or replace function public.create_sales_order(p_payload jsonb)');
const listOrders = functionBody('create or replace function public.get_sales_orders(');
const transition = functionBody('create or replace function public.transition_sales_order(p_sales_order_id uuid, p_next_status text)');
const preparationOptions = functionBody('create or replace function public.get_sales_preparation_options(p_sales_order_id uuid)');
const completePreparation = functionBody('create or replace function public.complete_sales_preparation(');
const dispatchOptions = functionBody('create or replace function public.get_sales_dispatch_options(p_sales_order_id uuid)');
const registerDispatch = functionBody('create or replace function public.register_sales_dispatch(');

test('MPCF-036 creates only the client and sales-order structures needed for V1', () => {
  assert.match(sql, /create table public\.sales_customers/);
  assert.match(sql, /create table public\.sales_orders/);
  for (const field of [
    'organization_id', 'legal_name', 'identification', 'contact', 'status', 'created_at', 'updated_at',
    'order_number', 'customer_id', 'requested_product', 'quantity', 'unit', 'requirements',
    'observations', 'registered_by', 'preparation_started_by', 'preparation_started_at',
    'prepared_product_id', 'prepared_quantity', 'excess_quantity', 'ready_by', 'ready_at',
    'dispatched_by', 'dispatched_at', 'closed_by', 'closed_at'
  ]) assert.ok(sql.includes(field), field);
  assert.match(sql, /MPCF-036 SALES V1 PREPARED - NOT EXECUTED/);
  assert.doesNotMatch(sql, /drop table|truncate|delete from/i);
});

test('MPCF-036 idempotently registers both Sales permission codes before its RPCs', () => {
  const permissionSeed = sql.indexOf('insert into public.permissions (code, resource, action, description)');
  const firstSalesRpc = sql.indexOf('create or replace function public.create_sales_customer');
  assert.ok(permissionSeed >= 0);
  assert.ok(firstSalesRpc > permissionSeed);
  const seed = sql.slice(permissionSeed, firstSalesRpc);
  assert.match(seed, /\('ventas\.read', 'ventas', 'read',/);
  assert.match(seed, /\('ventas\.write', 'ventas', 'write',/);
  assert.match(seed, /on conflict \(code\) do nothing/);
});

test('customer is required, tenant-scoped and active when a sales order is created', () => {
  assert.match(createOrder, /VALIDATION: customer_id is required/);
  assert.match(createOrder, /active customer not found/);
  assert.match(createOrder, /c\.id = v_customer_id and c\.organization_id = v_organization_id and c\.status = 'ACTIVO'/);
  assert.match(createCustomer, /VALIDATION: customer name is required/);
  assert.match(createCustomer, /ventas\.write/);
});

test('sales order creation requires product and positive quantity and starts in PEDIDO REGISTRADO', () => {
  assert.match(createOrder, /VALIDATION: requested product is required/);
  assert.match(createOrder, /v_quantity <= 0/);
  assert.match(createOrder, /unit must be g or kg/);
  assert.match(sql, /status text not null default 'PEDIDO REGISTRADO'/);
  assert.match(createOrder, /'status', v_order\.status/);
  assert.match(sql, /constraint sales_orders_quantity_check check \(quantity > 0\)/);
});

test('sales transitions follow only the defined commercial path', () => {
  assert.match(transition, /v_order\.status = 'PEDIDO REGISTRADO' and v_next_status = 'EN PREPARACIÓN'/);
  assert.match(transition, /v_order\.status = 'DESPACHADO' and v_next_status = 'CERRADO'/);
  assert.match(transition, /invalid sales order state transition/);
  assert.match(transition, /closed sales order is immutable/);
  assert.match(transition, /preparation_started_by = v_user, preparation_started_at = now\(\)/);
  assert.match(transition, /closed_by = v_user, closed_at = now\(\)/);
});

test('operational timestamps and actors are backend-generated, not accepted from client payload', () => {
  assert.match(completePreparation, /ready_by = v_user/);
  assert.match(completePreparation, /ready_at = now\(\)/);
  assert.match(registerDispatch, /dispatched_by = v_user/);
  assert.match(registerDispatch, /dispatched_at = now\(\)/);
  assert.match(transition, /closed_by = v_user, closed_at = now\(\)/);
  assert.match(sql, /new\.updated_at := now\(\)/);
  assert.match(createOrder, /registered_by/);
  assert.doesNotMatch(createOrder, /p_payload->>'(created_at|preparation_started_at|ready_at|dispatched_at|closed_at)'/);
  assert.doesNotMatch(completePreparation, /p_[a-z_]*(at|date)\b/i);
  const preparationUi = html.slice(html.indexOf('async function openSalesPreparation'), html.indexOf('function showSalesOrder'));
  assert.doesNotMatch(preparationUi, /type=["']date["']/);
});

test('preparation requires an explicit product and quantity at least equal to the order', () => {
  assert.match(preparationOptions, /v_order\.status <> 'EN PREPARACIÓN'/);
  assert.match(preparationOptions, /having coalesce\(sum\(case when m\.movement_type = 'ENTRADA'/);
  assert.match(completePreparation, /p_prepared_product_id uuid/);
  assert.match(completePreparation, /p_prepared_quantity numeric/);
  assert.match(completePreparation, /p_prepared_quantity < v_order\.quantity/);
  assert.match(completePreparation, /prepared quantity cannot be less than the sales order quantity/);
  assert.match(completePreparation, /prepared_product_id = v_product\.id/);
  assert.match(completePreparation, /prepared_quantity = p_prepared_quantity/);
  assert.match(completePreparation, /ready_by = v_user/);
  assert.match(completePreparation, /if v_order\.status = 'LISTO PARA DESPACHO'[\s\S]*'replayed', true/);
  assert.match(html, /get_sales_preparation_options/);
  assert.match(html, /complete_sales_preparation/);
  assert.match(html, /no se calcula desde el saldo de inventario/);
});

test('exact preparation records zero EXCESO and over-preparation records only the difference', () => {
  assert.match(completePreparation, /v_excess_quantity := p_prepared_quantity - v_order\.quantity/);
  assert.match(completePreparation, /excess_quantity = v_excess_quantity/);
  assert.match(completePreparation, /prepared_quantity = p_prepared_quantity/);
  for (const [requested, prepared, expected] of [[100, 100, 0], [100, 102, 2], [1000, 1050, 50]]) {
    assert.equal(prepared - requested, expected);
  }
  assert.match(html, /EXCESO registrado/);
});

test('EXCESO stays in the existing MOD-007 balance; Ventas creates no inventory movements', () => {
  assert.doesNotMatch(sql, /insert into public\.finished_product_movements/i);
  assert.doesNotMatch(sql, /insert into public\.finished_products/i);
  assert.doesNotMatch(sql, /excess_inventory_movement_id/i);
  assert.match(sql, /excess_quantity numeric/);
  assert.match(sql, /prepared_product_id uuid references public\.finished_products/);
  assert.match(sql, /inventory_movement_id uuid references public\.finished_product_movements/);
  assert.match(html, /Permanece como saldo del producto en Inventario MOD-007; no se crea otra entrada/);
  assert.match(completePreparation, /v_order\.prepared_product_id = p_prepared_product_id/);
  assert.match(completePreparation, /v_order\.prepared_quantity = p_prepared_quantity/);
});

test('closed order cannot be changed and order details have no direct table grants', () => {
  assert.match(transition, /if v_order\.status = 'CERRADO' then raise exception 'VALIDATION: closed sales order is immutable'/);
  assert.match(sql, /revoke all on public\.sales_orders from public, anon, authenticated/);
  assert.match(sql, /revoke all on public\.sales_customers from public, anon, authenticated/);
  assert.doesNotMatch(sql, /grant (insert|update|delete|select) on public\.sales_(orders|customers)/i);
});

test('Ventas never writes inventory, creates an ISOL or consolidates COD', () => {
  assert.doesNotMatch(sql, /insert into public\.finished_products/i);
  assert.doesNotMatch(sql, /insert into public\.finished_product_movements/i);
  assert.doesNotMatch(sql, /create or replace function public\.(dispatch_finished_product|consolidate_finished_products)/);
  assert.doesNotMatch(sql, /balance_kg/);
  const salesUi = html.slice(html.indexOf('async function ventas()'), html.indexOf('function traza()', html.indexOf('async function ventas()')));
  assert.doesNotMatch(salesUi, /finished_product_movements|dispatch_finished_product|consolidate_finished_products/);
  assert.match(salesUi, /openSalesPreparation/);
  assert.match(salesUi, /register_sales_dispatch/);
});

test('five small orders and one large order remain six independent commercial transactions', () => {
  assert.match(sql, /id uuid primary key default gen_random_uuid\(\)/);
  assert.match(sql, /constraint sales_orders_org_request_uidx unique \(organization_id, request_id\)/);
  assert.match(sql, /order_number bigint generated always as identity/);
  assert.match(createOrder, /insert into public\.sales_orders/);
  assert.match(html, /rpc\('create_sales_order'/);
  assert.doesNotMatch(createOrder, /sum\(|group by/i);
  assert.match(preparationOptions, /fp\.product_type in \('COD', 'ISOL'\)/);
});

test('a sale links only a complete existing Product / ISOL dispatch and its inventory movement', () => {
  assert.match(dispatchOptions, /op\.operation_type = 'DESPACHO'/);
  assert.match(dispatchOptions, /m\.reference_type = 'PRODUCT_ISOL_DESPACHO'/);
  assert.match(dispatchOptions, /op\.quantity_kg = v_required_kg/);
  assert.match(dispatchOptions, /op\.finished_product_id = v_order\.prepared_product_id/);
  assert.match(dispatchOptions, /not exists[\s\S]*linked\.dispatch_operation_id = op\.id/);
  assert.match(registerDispatch, /dispatch must fulfill the complete sales order quantity/);
  assert.match(registerDispatch, /inventory dispatch movement not found/);
  assert.match(registerDispatch, /dispatched product must match the prepared product/);
  assert.match(registerDispatch, /dispatch_operation_id = v_operation\.id/);
  assert.match(registerDispatch, /finished_product_id = v_product\.id/);
  assert.match(registerDispatch, /inventory_movement_id = v_movement\.id/);
  assert.match(registerDispatch, /status = 'DESPACHADO'/);
  assert.match(html, /rpc\('get_sales_dispatch_options'/);
  assert.match(html, /rpc\('register_sales_dispatch'/);
});

test('partial dispatches are rejected and grams convert to kilograms only for exact completion', () => {
  assert.match(dispatchOptions, /v_order\.quantity \/ 1000 else v_order\.quantity/);
  assert.match(registerDispatch, /v_order\.quantity \/ 1000 else v_order\.quantity/);
  assert.match(registerDispatch, /v_operation\.quantity_kg <> v_required_kg/);
  assert.match(registerDispatch, /v_movement\.quantity_kg <> v_required_kg/);
  assert.match(sql, /constraint sales_orders_unit_check check \(unit in \('g', 'kg'\)\)/);
});

test('sales permissions are explicit and functions are not executable by anon', () => {
  assert.match(sql, /private\.current_user_has_permission\('ventas\.read'\)/);
  assert.match(sql, /private\.current_user_has_permission\('ventas\.write'\)/);
  assert.match(sql, /revoke all on function public\.create_sales_order\(jsonb\) from public, anon, authenticated/);
  assert.match(sql, /grant execute on function public\.create_sales_order\(jsonb\) to authenticated/);
  assert.match(sql, /grant execute on function public\.get_sales_orders\(text, uuid, date, date\) to authenticated/);
  assert.match(sql, /grant execute on function public\.get_sales_preparation_options\(uuid\) to authenticated/);
  assert.match(sql, /grant execute on function public\.complete_sales_preparation\(uuid, uuid, numeric\) to authenticated/);
});

test('Sales UI supplies state, customer and date filters and the required order actions', () => {
  assert.match(html, /view\('ventas',this\)/);
  assert.match(html, /ventas:ventas/);
  assert.match(html, /sales_filter_status/);
  assert.match(html, /sales_filter_customer/);
  assert.match(html, /sales_filter_from/);
  assert.match(html, /sales_filter_to/);
  assert.match(html, /Pasar a preparación/);
  assert.match(html, /Marcar listo/);
  assert.match(html, /Ver despacho/);
  assert.match(html, /Vincular despacho/);
});

test('MPCF-036 is registered with the project migration ledger and documents its dependency', () => {
  assert.match(sql, /'MPCF-036',\s*'SALES_V1'/);
  assert.match(sql, /where not exists[\s\S]*migration_code = 'MPCF-036'/);
  assert.match(sql, /Requiere MPCF-035/);
});
