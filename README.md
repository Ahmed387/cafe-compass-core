# Cafe Core System

Phase 0 — Coffee Shop Management System

Foundation, Database Architecture, Authentication, RBAC & Core Business Rules

Build the foundation of a production-ready coffee shop management system.

This is a real business management application, not a demo, mockup, prototype, or static dashboard.

The system will eventually manage:

POS

Cashier shifts

Orders

Payments

Inventory

Recipes

Ingredients

Suppliers

Purchases

Waste

Refunds

Discounts

Kitchen Display System

Employees

Payroll

Expenses

Partners

Profit distribution

Branches

QR menu

Thermal printing

Reports

Audit logs

However, DO NOT implement all future modules in this phase.

This phase is strictly responsible for creating a strong foundation, database architecture, authentication, authorization, users, roles, permissions, partners, branches, audit logging, and core financial/business structures.

The architecture MUST support all future phases without requiring destructive database changes or rewriting the authentication/authorization model.

1. Technology & Architecture

Use a modern production-ready architecture.

Preferred stack:

React

TypeScript

Tailwind CSS

shadcn/ui

Supabase

PostgreSQL

Supabase Auth

Row Level Security (RLS)

Use TypeScript throughout the frontend.

Use PostgreSQL/Supabase for persistent data.

Do not use localStorage as the primary database.

Do not use fake/mock data for real business entities.

Create proper database tables, relationships, constraints, indexes, and RLS policies.

The system must be responsive and touch-friendly.

Desktop is the primary interface, but the architecture must support tablets and mobile devices.

2. Application Identity

Create the application as a professional Coffee Shop Management System.

The UI should feel like a modern POS/business management platform.

Design principles:

Clean

Professional

Fast

Touch-friendly

Easy to understand

Suitable for daily use by non-technical employees

Responsive

Clear financial information

Strong visual hierarchy

Avoid unnecessary animations

Avoid clutter

The system must support Arabic and English from the beginning.

Use proper RTL support for Arabic.

Currency must be configurable, with EGP as the initial/default currency.

Do not hard-code currency logic.

3. Multi-Branch Architecture

The system must support multiple branches from the beginning.

Even if the business currently has only one branch, the database must be designed for multiple branches.

Create:

companies

Fields:

id

name

legal_name

logo_url

currency

timezone

default_language

tax_enabled

tax_rate

created_at

updated_at

branches

Fields:

id

company_id

name

code

address

phone

is_active

created_at

updated_at

Every operational entity that belongs to a physical branch must be capable of being associated with a branch.

Do not assume there will only ever be one branch.

4. Authentication

Use Supabase Auth.

Users must authenticate securely.

Support:

Email

Password

Session management

Password reset

Logout

Protected routes

Do not expose passwords in application tables.

Do not store plaintext passwords.

Create a separate application profile table associated with the authenticated Supabase user.

5. User Profile

Create:

user_profiles

Fields:

id

auth_user_id

company_id

first_name

last_name

display_name

email

phone

employee_code

avatar_url

preferred_language

is_active

created_at

updated_at

A user belongs to a company.

Users may be assigned to one or more branches depending on permissions.

Do not assume that every user can access every branch.

6. Roles & Permissions

Implement a granular RBAC system.

Do NOT hard-code permissions only in frontend code.

Permissions must be stored in the database.

Create:

roles

Fields:

id

company_id

name

description

is_system_role

created_at

updated_at

permissions

Fields:

id

key

name

description

module

created_at

role_permissions

Fields:

role_id

permission_id

user_roles

Fields:

user_id

role_id

branch_id nullable

A user may have different roles in different branches if needed.

7. Initial Roles

Create these initial system roles:

Super Admin

Full access to everything.

Manager

Operational management permissions.

Partner

Access to financial information assigned to the partner.

Cashier

POS and shift-related permissions.

Kitchen Staff

Kitchen Display System permissions.

Inventory Staff

Inventory and purchasing permissions.

Accountant

Expenses, payroll, financial reporting and accounting permissions.

However, Super Admin must be able to:

Create custom roles

Edit permissions

Assign permissions

Assign roles

Disable users

Change branch access

Do not assume the predefined roles are sufficient forever.

8. Permission System

Create granular permissions.

Examples:

Users

users.view

users.create

users.update

users.disable

users.manage_roles

Products

products.view

products.create

products.update

products.change_price

products.disable

POS

pos.view

pos.create_order

pos.cancel_order

pos.void_item

pos.apply_discount

pos.process_refund

pos.reprint_receipt

Shifts

shifts.open

shifts.close

shifts.view

shifts.adjust_cash

Inventory

inventory.view

inventory.adjust

inventory.waste

inventory.transfer

Purchasing

purchases.view

purchases.create

purchases.update

purchases.approve

Expenses

expenses.view

expenses.create

expenses.approve

expenses.edit

Kitchen

kitchen.view

kitchen.update_order_status

Partners

partners.view

partners.manage

partners.view_profit

partners.manage_profit_distribution

partners.manage_withdrawals

Payroll

payroll.view

payroll.manage

payroll.approve

Reports

reports.sales

reports.inventory

reports.expenses

reports.profit

reports.payroll

reports.partners

reports.cashier

Settings

settings.view

settings.manage

Audit

audit.view

The Super Admin must be able to control which user can perform each sensitive action.

9. Super Admin

The first Super Admin is the highest-level administrator of the company.

Super Admin can:

Create users

Disable users

Create roles

Modify permissions

Assign roles

Assign branches

Create partners

Manage partner investments

Manage partner ownership percentages

Manage products

Manage prices

Manage recipes

Manage inventory

Manage suppliers

Manage purchases

Manage expenses

Manage payroll

Manage branches

View all reports

Manage system settings

View audit logs

Do not allow another user to bypass Super Admin permissions.

10. Partner Architecture

Partners are business owners/investors.

Create:

partners

Fields:

id

company_id

user_id nullable

name

email

phone

status

created_at

updated_at

A partner may have a linked application user account.

The Super Admin decides whether the partner can log in.

11. Partner Capital Contributions

Create:

partner_capital_contributions

Fields:

id

company_id

partner_id

amount

currency

contribution_date

payment_method

reference

notes

created_by

created_at

The system must maintain a complete history.

Do not overwrite previous capital contributions.

If a partner contributes additional money later, create a new contribution transaction.

12. Partner Ownership Percentage

Ownership percentage must be calculated from the partners' total capital contributions.

Example:

Partner A:

500,000 EGP

Partner B:

300,000 EGP

Partner C:

200,000 EGP

Total:

1,000,000 EGP

Ownership:

A = 50%

B = 30%

C = 20%

The system must validate that ownership percentages are consistent with the business configuration.

Do not allow invalid ownership totals.

Super Admin must be able to review the calculated ownership.

Do not manually modify historical ownership calculations without creating an auditable record.

13. Partner Profit Wallet

Create a financial ledger architecture for partner balances.

Do NOT simply store one editable "balance" field and modify it manually.

Create:

partner_ledger_transactions

Fields:

id

company_id

partner_id

transaction_type

amount

currency

reference_type

reference_id

description

transaction_date

created_by

created_at

Possible transaction types:

profit_distribution

withdrawal

capital_contribution

adjustment

The partner balance should be calculated from the ledger.

This will eventually allow:

Profit Distribution:

+50,000

Withdrawal:

-10,000

Current Partner Balance:

40,000

Every transaction must be traceable.

14. Monthly Profit Distribution

The final profit calculation system will be implemented in a future phase.

However, the database architecture MUST support:

Monthly accounting periods

Net profit

Partner ownership percentage

Automatic profit allocation

Partner ledger entries

Profit distribution history

Example:

Monthly Net Profit:

100,000 EGP

Partner A = 50%

Partner B = 30%

Partner C = 20%

Create ledger transactions:

A +50,000

B +30,000

C +20,000

Do not implement fake profit calculations in this phase.

Only prepare the architecture.

15. Financial Periods

Create:

accounting_periods

Fields:

id

company_id

period_type

start_date

end_date

status

closed_at

closed_by

created_at

Possible status:

open

closed

The system must eventually support monthly profit calculation.

Closed financial periods should not be freely editable.

16. Audit Log

This is mandatory.

Create:

audit_logs

Fields:

id

company_id

branch_id nullable

user_id

action

module

entity_type

entity_id

old_values JSONB nullable

new_values JSONB nullable

reason nullable

ip_address nullable

user_agent nullable

created_at

Audit important actions including:

Login

Logout

User creation

Permission changes

Role changes

Product changes

Price changes

Financial changes

Order cancellation

Refund

Void

Discount

Inventory adjustment

Waste

Expense

Purchase

Partner transactions

Payroll

Settings changes

Never allow ordinary users to delete audit logs.

Prefer append-only audit records.

17. Financial Data Rules

Financial records must never be hard-deleted.

Examples:

Orders

Payments

Refunds

Expenses

Purchases

Payroll transactions

Partner transactions

Cash movements

Use statuses such as:

active

cancelled

voided

reversed

when appropriate.

Every reversal must reference the original transaction.

18. Future POS Architecture

Do not implement the POS in this phase.

However, prepare the architecture for:

Products

Categories

Product variants

Sizes

Modifiers

Orders

Order items

Payments

Refunds

Discounts

Voids

Cashier shifts

An order must eventually be associated with:

company

branch

cashier

shift

customer/order reference if needed

payment

kitchen workflow

19. Future Inventory Architecture

Prepare for:

Ingredients

Products

Units

Recipes

Recipe ingredients

Recipe versions

Stock locations

Stock movements

Minimum stock

Waste

Adjustments

Purchases

Inventory must eventually use immutable stock movement records rather than simply changing a quantity without history.

20. Future Kitchen Architecture

Prepare for:

Kitchen stations

Orders

Order items

Station assignments

Preparation statuses

Future order status workflow:

New

→ Preparing

→ Ready

→ Completed

21. Future Employee & Payroll Architecture

Prepare the architecture for:

Employees

Attendance

Salaries

Advances

Bonuses

Deductions

Payroll periods

Payroll transactions

Cashier penalties resulting from approved discounts/refunds or other configurable rules must eventually be represented as explicit payroll deductions.

Do not implement payroll calculations in this phase.

22. Future Expense Architecture

Prepare for:

Expense categories

Expenses

Expense approvals

Payment methods

Branch association

Attachments

Audit trail

23. Future Payment Architecture

The future system must support:

Cash

Cash drawer.

Wallet

Track:

Sender number

Receiver number

Provider

Transaction reference

Amount

InstaPay

Track:

Sender number

Receiver number

Transaction reference

Amount

Payments must be linked to orders and shifts.

Payment methods must be configurable.

24. Security

Implement strong Supabase Row Level Security.

Rules must ensure:

Users only see data they are authorized to see.

Branch-level access is enforced server-side.

Partner data is protected.

Sensitive financial data is not exposed to unauthorized users.

Frontend permission checks are NOT considered sufficient security.

Database RLS must enforce authorization.

Never rely only on hiding UI buttons.

25. Partner Privacy

A Partner should not automatically see another Partner's private information.

The system must support permissions such as:

View own partner account

View own profit

View own ledger

View company-wide sales

View company-wide expenses

View other partner information

Super Admin controls these permissions.

26. Branch Access

Users may be assigned to:

One branch

Multiple branches

All branches

Super Admin controls this.

A Cashier should normally only see the branch/shift assigned to them.

A Partner may have company-level financial visibility depending on permissions.

27. UI Foundation

Create:

Login Page

Email

Password

Remember session

Forgot password

Main Layout

Sidebar navigation.

Top bar:

User

Role

Current branch

Language

Notifications

Logout

The navigation must dynamically show modules according to permissions.

Do not show unauthorized modules.

28. Super Admin Dashboard Foundation

Create a basic dashboard shell.

Show only foundation-level information for now:

Total users

Active users

Total branches

Total partners

Current accounting period

System status

Recent audit activity

Do NOT create fake sales/profit numbers.

If a future module has not been implemented, do not display fake data.

29. Notifications Foundation

Prepare a notification architecture.

Future alerts will include:

Low stock

Shift discrepancy

Refund

Large discount

Waste

Approval required

Payment discrepancy

Payroll event

Create a reusable notification system.

30. System Settings

Create a settings architecture for:

Company name

Logo

Currency

Language

Timezone

Tax enabled

Tax rate

Branch settings

Receipt settings

Permission defaults

Do not hard-code these values.

31. Data Integrity

Use:

Foreign keys

Unique constraints

Check constraints

Proper indexes

NOT NULL where appropriate

Timestamps

Soft-delete/status patterns where appropriate

Use UUID primary keys where appropriate.

Use database-generated timestamps.

Avoid duplicated data when a relationship should be used.

32. Important Business Rule

Never allow a user to manually edit derived financial values.

Examples:

Do not allow direct editing of:

Partner balance

Partner profit balance

Ownership-derived values

Inventory balance

Shift expected cash

Net profit

These must be derived from transactions and business rules.

33. Error Handling

Use clear user-friendly error messages.

Do not expose raw database errors to normal users.

Log technical errors appropriately.

34. Empty States

Every page must have meaningful empty states.

Example:

"No partners have been added yet."

Do not use fake placeholder records.

35. Seed Data

Only create minimal safe seed data necessary for testing:

One development company

One development branch

One Super Admin

Do not create fake sales, fake expenses, fake profits, fake orders, fake partners, or fake inventory.

36. Development Safety

Before changing the database schema:

Check existing schema

Avoid duplicate tables

Avoid duplicate columns

Avoid conflicting migrations

Preserve existing data

Use proper migrations.

Do not destroy existing tables simply to simplify implementation.

37. Future Compatibility

The following future modules MUST be able to integrate with this foundation:

POS

Products

Recipes

Inventory

Suppliers

Purchases

Orders

Payments

Cashier shifts

Kitchen Display

Expenses

Payroll

Partners

Profit distribution

QR Menu

Thermal printing

Reports

Multi-branch

Do not implement these modules now.

Only create the foundation necessary for them.

38. Deliverables for This Phase

Complete the following:

Supabase project/database structure

Database migrations

Authentication

User profiles

Companies

Branches

Roles

Permissions

Role permissions

User roles

Partner foundation

Partner capital contribution foundation

Partner ledger foundation

Accounting periods

Audit logs

Notifications foundation

Settings foundation

RLS policies

Protected routes

Permission-aware navigation

Super Admin foundation dashboard

Arabic/English foundation

RTL support

Responsive layout

39. Acceptance Criteria

Before considering this phase complete, verify:

Super Admin can log in.

Super Admin can create users.

Super Admin can disable users.

Super Admin can create roles.

Super Admin can assign permissions.

Super Admin can assign users to branches.

Super Admin can create partners.

Super Admin can record partner capital contributions.

Partner ownership can be calculated from capital contributions.

Partner ledger architecture exists.

Accounting periods exist.

Audit logs are created for important actions.

Unauthorized users cannot access protected routes.

RLS prevents unauthorized database access.

Arabic RTL works correctly.

English LTR works correctly.

No fake financial data is displayed.

No financial records can be hard-deleted.

The system supports multiple branches.

The architecture is ready for the next phases.

40. CRITICAL INSTRUCTION

Do not attempt to build the entire coffee shop system in this phase.

Do not skip database architecture.

Do not use mock financial logic.

Do not create fake sales or profit data.

Do not hard-code roles or permissions in a way that prevents future customization.

Do not hard-delete financial records.

Do not bypass RLS.

Do not create duplicate tables when future phases are implemented.

Build this phase as the stable foundation for a real production system.

After implementation, provide a concise summary of:

Tables created

Relationships created

RLS policies created

Roles and permissions created

Routes/pages created

Remaining work for Phase 1

Any technical limitations or decisions that need approval

STOP after completing this foundation.

Do not automatically proceed to Phase 1
وقولي انت نفذت ايه وباقي ايه في الاخر

This project was built with [Lovable](https://lovable.dev).

**Live app**: https://cafe-compass-core.lovable.app

## Build with Lovable

Continue developing this project in the [Lovable editor](https://lovable.dev/projects/a93950f9-f73c-41a0-acf1-9ffe93faddc3).

- **Ship faster**: describe what you want to build and Lovable handles the code.
- **Stay in sync**: every change made in Lovable is committed straight to this repository.
- **Full ownership**: this code is yours. Push to `main` on GitHub and your changes sync back into Lovable, ready for your next prompt.

## Development

Prefer working locally? You need Node.js and npm — [install with nvm](https://github.com/nvm-sh/nvm#installing-and-updating).

```sh
git clone <this-repository-url>
cd <repository-name>
npm i
npm run dev
```
