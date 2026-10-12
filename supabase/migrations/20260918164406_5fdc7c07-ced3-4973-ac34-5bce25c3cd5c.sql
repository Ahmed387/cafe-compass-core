create or replace function public.delete_category_hard(_category_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare _company uuid := current_company_id();
        _linked int;
begin
  if not (public.is_super_admin() or public.has_permission('products.update')) then
    raise exception 'not authorized';
  end if;
  if not exists (select 1 from public.categories where id = _category_id and company_id = _company) then
    raise exception 'category not found';
  end if;

  select count(*) into _linked from public.products where category_id = _category_id;
  if _linked > 0 then
    raise exception 'لا يمكن حذف هذا التصنيف لوجود منتجات مرتبطة به. يرجى نقل المنتجات أو حذفها أولاً';
  end if;

  delete from public.categories where id = _category_id;
  perform public.log_audit('category.delete', 'products', 'categories', _category_id, null,
    jsonb_build_object('deleted_by', auth.uid(), 'timestamp', now()), null, null);
  return jsonb_build_object('mode', 'deleted');
end;
$$;

create or replace function public.delete_product_hard(_product_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare _company uuid := current_company_id();
        _sales int;
        _bundles int;
begin
  if not (public.is_super_admin() or public.has_permission('products.update')) then
    raise exception 'not authorized';
  end if;
  if not exists (select 1 from public.products where id = _product_id and company_id = _company) then
    raise exception 'product not found';
  end if;

  select count(*) into _sales from public.order_items where product_id = _product_id;
  select count(*) into _bundles from public.offer_bundle_items where product_id = _product_id;

  if _sales > 0 or _bundles > 0 then
    update public.products
       set is_active = false, is_available = false, show_on_public_menu = false
     where id = _product_id;
    perform public.log_audit('product.deactivated', 'products', 'products', _product_id, null,
      jsonb_build_object('sales_lines', _sales, 'bundle_lines', _bundles), null, null);
    return jsonb_build_object('mode', 'deactivated', 'sales_lines', _sales, 'bundle_lines', _bundles);
  end if;

  delete from public.product_recipes where product_id = _product_id;
  delete from public.product_modifier_groups where product_id = _product_id;
  delete from public.product_sizes where product_id = _product_id;
  delete from public.product_branch_settings where product_id = _product_id;
  delete from public.product_offers where product_id = _product_id;
  delete from public.products where id = _product_id;

  perform public.log_audit('product.delete', 'products', 'products', _product_id, null,
    jsonb_build_object('deleted_by', auth.uid(), 'timestamp', now()), null, null);
  return jsonb_build_object('mode', 'deleted');
end;
$$;

revoke all on function public.delete_category_hard(uuid) from public, anon;
revoke all on function public.delete_product_hard(uuid) from public, anon;
grant execute on function public.delete_category_hard(uuid) to authenticated, service_role;
grant execute on function public.delete_product_hard(uuid) to authenticated, service_role;