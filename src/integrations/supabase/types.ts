export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      accounting_periods: {
        Row: {
          auto_created: boolean
          closed_at: string | null
          closed_by: string | null
          company_id: string
          created_at: string
          delete_reason: string | null
          deleted_at: string | null
          deleted_by: string | null
          distribution_frozen: boolean
          distribution_frozen_at: string | null
          distribution_frozen_by: string | null
          end_date: string
          id: string
          is_adjustment: boolean
          is_open_ended: boolean
          override_until: string | null
          period_type: Database["public"]["Enums"]["period_type"]
          start_date: string
          status: Database["public"]["Enums"]["period_status"]
        }
        Insert: {
          auto_created?: boolean
          closed_at?: string | null
          closed_by?: string | null
          company_id: string
          created_at?: string
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          distribution_frozen?: boolean
          distribution_frozen_at?: string | null
          distribution_frozen_by?: string | null
          end_date: string
          id?: string
          is_adjustment?: boolean
          is_open_ended?: boolean
          override_until?: string | null
          period_type?: Database["public"]["Enums"]["period_type"]
          start_date: string
          status?: Database["public"]["Enums"]["period_status"]
        }
        Update: {
          auto_created?: boolean
          closed_at?: string | null
          closed_by?: string | null
          company_id?: string
          created_at?: string
          delete_reason?: string | null
          deleted_at?: string | null
          deleted_by?: string | null
          distribution_frozen?: boolean
          distribution_frozen_at?: string | null
          distribution_frozen_by?: string | null
          end_date?: string
          id?: string
          is_adjustment?: boolean
          is_open_ended?: boolean
          override_until?: string | null
          period_type?: Database["public"]["Enums"]["period_type"]
          start_date?: string
          status?: Database["public"]["Enums"]["period_status"]
        }
        Relationships: [
          {
            foreignKeyName: "accounting_periods_closed_by_fkey"
            columns: ["closed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "accounting_periods_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "accounting_periods_distribution_frozen_by_fkey"
            columns: ["distribution_frozen_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      app_settings: {
        Row: {
          branch_id: string | null
          company_id: string
          created_at: string
          id: string
          key: string
          scope: string
          updated_at: string
          value: Json
        }
        Insert: {
          branch_id?: string | null
          company_id: string
          created_at?: string
          id?: string
          key: string
          scope?: string
          updated_at?: string
          value?: Json
        }
        Update: {
          branch_id?: string | null
          company_id?: string
          created_at?: string
          id?: string
          key?: string
          scope?: string
          updated_at?: string
          value?: Json
        }
        Relationships: [
          {
            foreignKeyName: "app_settings_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "app_settings_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      attendance: {
        Row: {
          branch_id: string | null
          check_in: string | null
          check_out: string | null
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          minutes_worked: number
          notes: string | null
          permission_hours: number | null
          status: string
          updated_at: string
          user_id: string
          work_date: string
        }
        Insert: {
          branch_id?: string | null
          check_in?: string | null
          check_out?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          minutes_worked?: number
          notes?: string | null
          permission_hours?: number | null
          status?: string
          updated_at?: string
          user_id: string
          work_date?: string
        }
        Update: {
          branch_id?: string | null
          check_in?: string | null
          check_out?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          minutes_worked?: number
          notes?: string | null
          permission_hours?: number | null
          status?: string
          updated_at?: string
          user_id?: string
          work_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "attendance_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "attendance_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_logs: {
        Row: {
          action: string
          branch_id: string | null
          company_id: string | null
          created_at: string
          entity_id: string | null
          entity_type: string | null
          id: string
          ip_address: string | null
          module: string
          new_values: Json | null
          old_values: Json | null
          reason: string | null
          user_agent: string | null
          user_id: string | null
        }
        Insert: {
          action: string
          branch_id?: string | null
          company_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          ip_address?: string | null
          module: string
          new_values?: Json | null
          old_values?: Json | null
          reason?: string | null
          user_agent?: string | null
          user_id?: string | null
        }
        Update: {
          action?: string
          branch_id?: string | null
          company_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          ip_address?: string | null
          module?: string
          new_values?: Json | null
          old_values?: Json | null
          reason?: string | null
          user_agent?: string | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      backup_history: {
        Row: {
          company_id: string
          created_at: string
          drive_file_id: string | null
          drive_folder_id: string | null
          drive_link: string | null
          error_message: string | null
          file_name: string | null
          file_size_bytes: number | null
          id: string
          status: string
        }
        Insert: {
          company_id: string
          created_at?: string
          drive_file_id?: string | null
          drive_folder_id?: string | null
          drive_link?: string | null
          error_message?: string | null
          file_name?: string | null
          file_size_bytes?: number | null
          id?: string
          status: string
        }
        Update: {
          company_id?: string
          created_at?: string
          drive_file_id?: string | null
          drive_folder_id?: string | null
          drive_link?: string | null
          error_message?: string | null
          file_name?: string | null
          file_size_bytes?: number | null
          id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "backup_history_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      branch_stock: {
        Row: {
          bar_quantity: number
          branch_id: string
          created_at: string
          id: string
          item_id: string
          quantity: number
          updated_at: string
        }
        Insert: {
          bar_quantity?: number
          branch_id: string
          created_at?: string
          id?: string
          item_id: string
          quantity?: number
          updated_at?: string
        }
        Update: {
          bar_quantity?: number
          branch_id?: string
          created_at?: string
          id?: string
          item_id?: string
          quantity?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "branch_stock_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_stock_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
        ]
      }
      branches: {
        Row: {
          address: string | null
          code: string
          company_id: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          phone: string | null
          timezone: string | null
          updated_at: string
        }
        Insert: {
          address?: string | null
          code: string
          company_id: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          phone?: string | null
          timezone?: string | null
          updated_at?: string
        }
        Update: {
          address?: string | null
          code?: string
          company_id?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          phone?: string | null
          timezone?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "branches_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_accounts: {
        Row: {
          account_type: string
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          is_default: boolean
          key: string
          name: string
          name_ar: string | null
          notes: string | null
          opening_balance: number
          updated_at: string
        }
        Insert: {
          account_type?: string
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          is_default?: boolean
          key: string
          name: string
          name_ar?: string | null
          notes?: string | null
          opening_balance?: number
          updated_at?: string
        }
        Update: {
          account_type?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          is_default?: boolean
          key?: string
          name?: string
          name_ar?: string | null
          notes?: string | null
          opening_balance?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_accounts_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_accounts_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_transactions: {
        Row: {
          account_id: string
          amount: number
          category: string
          company_id: string
          created_at: string
          created_by: string | null
          description: string | null
          direction: string
          id: string
          method: string
          reference_id: string | null
          reference_type: string | null
          reversal_of: string | null
          status: Database["public"]["Enums"]["record_status"]
          transfer_group: string | null
          txn_date: string
        }
        Insert: {
          account_id: string
          amount: number
          category: string
          company_id: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          direction: string
          id?: string
          method?: string
          reference_id?: string | null
          reference_type?: string | null
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          transfer_group?: string | null
          txn_date?: string
        }
        Update: {
          account_id?: string
          amount?: number
          category?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          direction?: string
          id?: string
          method?: string
          reference_id?: string | null
          reference_type?: string | null
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          transfer_group?: string | null
          txn_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_transactions_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "cash_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_transactions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_transactions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_transactions_reversal_of_fkey"
            columns: ["reversal_of"]
            isOneToOne: false
            referencedRelation: "cash_transactions"
            referencedColumns: ["id"]
          },
        ]
      }
      categories: {
        Row: {
          company_id: string
          created_at: string
          display_order: number
          id: string
          is_active: boolean
          name: string
          name_ar: string | null
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          name: string
          name_ar?: string | null
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          name?: string
          name_ar?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "categories_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      companies: {
        Row: {
          created_at: string
          currency: string
          default_language: Database["public"]["Enums"]["app_language"]
          id: string
          is_active: boolean
          legal_name: string | null
          logo_url: string | null
          name: string
          tax_enabled: boolean
          tax_rate: number
          timezone: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          currency?: string
          default_language?: Database["public"]["Enums"]["app_language"]
          id?: string
          is_active?: boolean
          legal_name?: string | null
          logo_url?: string | null
          name: string
          tax_enabled?: boolean
          tax_rate?: number
          timezone?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          currency?: string
          default_language?: Database["public"]["Enums"]["app_language"]
          id?: string
          is_active?: boolean
          legal_name?: string | null
          logo_url?: string | null
          name?: string
          tax_enabled?: boolean
          tax_rate?: number
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      customer_points_transactions: {
        Row: {
          balance_after: number
          company_id: string
          created_at: string
          created_by: string | null
          customer_id: string
          description: string | null
          id: string
          kind: string
          order_id: string | null
          points: number
          voucher_id: string | null
        }
        Insert: {
          balance_after: number
          company_id: string
          created_at?: string
          created_by?: string | null
          customer_id: string
          description?: string | null
          id?: string
          kind: string
          order_id?: string | null
          points: number
          voucher_id?: string | null
        }
        Update: {
          balance_after?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string
          description?: string | null
          id?: string
          kind?: string
          order_id?: string | null
          points?: number
          voucher_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_points_transactions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_points_transactions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_points_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_points_transactions_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_vouchers: {
        Row: {
          amount: number
          code: string
          company_id: string
          created_at: string
          created_by: string | null
          customer_id: string
          expense_id: string | null
          expires_at: string | null
          id: string
          notes: string | null
          order_id: string | null
          points_cost: number
          redeemed_at: string | null
          redeemed_by: string | null
          settlement: string | null
          status: string
          updated_at: string
        }
        Insert: {
          amount: number
          code: string
          company_id: string
          created_at?: string
          created_by?: string | null
          customer_id: string
          expense_id?: string | null
          expires_at?: string | null
          id?: string
          notes?: string | null
          order_id?: string | null
          points_cost?: number
          redeemed_at?: string | null
          redeemed_by?: string | null
          settlement?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          amount?: number
          code?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string
          expense_id?: string | null
          expires_at?: string | null
          id?: string
          notes?: string | null
          order_id?: string | null
          points_cost?: number
          redeemed_at?: string | null
          redeemed_by?: string | null
          settlement?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "customer_vouchers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_vouchers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_vouchers_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_vouchers_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_vouchers_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_vouchers_redeemed_by_fkey"
            columns: ["redeemed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_wallet_transactions: {
        Row: {
          amount: number
          balance_after: number
          company_id: string
          created_at: string
          created_by: string | null
          customer_id: string
          description: string | null
          id: string
          kind: string
          order_id: string | null
        }
        Insert: {
          amount: number
          balance_after: number
          company_id: string
          created_at?: string
          created_by?: string | null
          customer_id: string
          description?: string | null
          id?: string
          kind: string
          order_id?: string | null
        }
        Update: {
          amount?: number
          balance_after?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string
          description?: string | null
          id?: string
          kind?: string
          order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_wallet_transactions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_wallet_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customer_wallet_transactions_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
        ]
      }
      cost_recalcs: {
        Row: {
          company_id: string
          cogs_delta: number
          created_by: string | null
          error: string | null
          first_date: string | null
          id: string
          lines_changed: number
          ran_at: string
          reason: string
        }
        Insert: {
          company_id: string
          cogs_delta?: number
          created_by?: string | null
          error?: string | null
          first_date?: string | null
          id?: string
          lines_changed?: number
          ran_at?: string
          reason: string
        }
        Update: {
          company_id?: string
          cogs_delta?: number
          created_by?: string | null
          error?: string | null
          first_date?: string | null
          id?: string
          lines_changed?: number
          ran_at?: string
          reason?: string
        }
        Relationships: []
      }
      customers: {
        Row: {
          barcode: string
          cashback_level: number
          cashback_progress: number
          code: string
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          last_visit_at: string | null
          name: string
          notes: string | null
          phone: string
          points_balance: number
          total_spent: number
          updated_at: string
          visits: number
          wallet_balance: number
        }
        Insert: {
          barcode: string
          cashback_level?: number
          cashback_progress?: number
          code: string
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          last_visit_at?: string | null
          name: string
          notes?: string | null
          phone: string
          points_balance?: number
          total_spent?: number
          updated_at?: string
          visits?: number
          wallet_balance?: number
        }
        Update: {
          barcode?: string
          cashback_level?: number
          cashback_progress?: number
          code?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          last_visit_at?: string | null
          name?: string
          notes?: string | null
          phone?: string
          points_balance?: number
          total_spent?: number
          updated_at?: string
          visits?: number
          wallet_balance?: number
        }
        Relationships: [
          {
            foreignKeyName: "customers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "customers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      development_fund_ledger: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          created_by: string | null
          description: string | null
          direction: string
          distribution_id: string | null
          entry_date: string
          id: string
          reversal_of: string | null
          status: Database["public"]["Enums"]["record_status"]
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          direction: string
          distribution_id?: string | null
          entry_date?: string
          id?: string
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          direction?: string
          distribution_id?: string | null
          entry_date?: string
          id?: string
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Relationships: [
          {
            foreignKeyName: "development_fund_ledger_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "development_fund_ledger_distribution_id_fkey"
            columns: ["distribution_id"]
            isOneToOne: false
            referencedRelation: "profit_distributions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "development_fund_ledger_reversal_of_fkey"
            columns: ["reversal_of"]
            isOneToOne: false
            referencedRelation: "development_fund_ledger"
            referencedColumns: ["id"]
          },
        ]
      }
      electronic_payment_settlements: {
        Row: {
          account_id: string
          amount: number
          batch_reference: string
          cash_transaction_id: string
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          payment_id: string
          settlement_date: string
        }
        Insert: {
          account_id: string
          amount: number
          batch_reference: string
          cash_transaction_id: string
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          payment_id: string
          settlement_date?: string
        }
        Update: {
          account_id?: string
          amount?: number
          batch_reference?: string
          cash_transaction_id?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          payment_id?: string
          settlement_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "electronic_payment_settlements_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "cash_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "electronic_payment_settlements_cash_transaction_id_fkey"
            columns: ["cash_transaction_id"]
            isOneToOne: false
            referencedRelation: "cash_transactions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "electronic_payment_settlements_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "electronic_payment_settlements_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "electronic_payment_settlements_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: true
            referencedRelation: "order_payments"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_advances: {
        Row: {
          advance_date: string
          amount: number
          company_id: string
          created_at: string
          created_by: string | null
          deduct_from: string | null
          deducted_amount: number
          id: string
          reason: string | null
          settled_at: string | null
          settled_payment_id: string | null
          status: Database["public"]["Enums"]["record_status"]
          updated_at: string
          user_id: string
        }
        Insert: {
          advance_date?: string
          amount: number
          company_id: string
          created_at?: string
          created_by?: string | null
          deduct_from?: string | null
          deducted_amount?: number
          id?: string
          reason?: string | null
          settled_at?: string | null
          settled_payment_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          updated_at?: string
          user_id: string
        }
        Update: {
          advance_date?: string
          amount?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          deduct_from?: string | null
          deducted_amount?: number
          id?: string
          reason?: string | null
          settled_at?: string | null
          settled_payment_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_advances_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_advances_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_advances_settled_payment_id_fkey"
            columns: ["settled_payment_id"]
            isOneToOne: false
            referencedRelation: "salary_payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_advances_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_salaries: {
        Row: {
          base_salary: number
          company_id: string
          created_at: string
          created_by: string | null
          effective_from: string
          id: string
          is_active: boolean
          notes: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          base_salary: number
          company_id: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          id?: string
          is_active?: boolean
          notes?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          base_salary?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          id?: string
          is_active?: boolean
          notes?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_salaries_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_salaries_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_salaries_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_categories: {
        Row: {
          company_id: string
          created_at: string
          id: string
          is_active: boolean
          name: string
          name_ar: string | null
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          name_ar?: string | null
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          name_ar?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_categories_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      expenses: {
        Row: {
          amount: number
          approved_at: string | null
          approved_by: string | null
          branch_id: string | null
          category_id: string | null
          company_id: string
          created_at: string
          created_by: string | null
          description: string | null
          expense_date: string
          id: string
          payment_method: string | null
          shift_id: string | null
          status: Database["public"]["Enums"]["record_status"]
          updated_at: string
          vendor: string | null
        }
        Insert: {
          amount: number
          approved_at?: string | null
          approved_by?: string | null
          branch_id?: string | null
          category_id?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          expense_date?: string
          id?: string
          payment_method?: string | null
          shift_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          updated_at?: string
          vendor?: string | null
        }
        Update: {
          amount?: number
          approved_at?: string | null
          approved_by?: string | null
          branch_id?: string | null
          category_id?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          description?: string | null
          expense_date?: string
          id?: string
          payment_method?: string | null
          shift_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          updated_at?: string
          vendor?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "expenses_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "expense_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      inventory_items: {
        Row: {
          bar_min_qty: number
          company_id: string
          cost_per_unit: number
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          min_qty: number
          name: string
          name_ar: string | null
          opening_cost: number | null
          sku: string | null
          unit: string
          updated_at: string
          waste_pct: number
        }
        Insert: {
          bar_min_qty?: number
          company_id: string
          cost_per_unit?: number
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          min_qty?: number
          name: string
          name_ar?: string | null
          opening_cost?: number | null
          sku?: string | null
          unit?: string
          updated_at?: string
          waste_pct?: number
        }
        Update: {
          bar_min_qty?: number
          company_id?: string
          cost_per_unit?: number
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          min_qty?: number
          name?: string
          name_ar?: string | null
          opening_cost?: number | null
          sku?: string | null
          unit?: string
          updated_at?: string
          waste_pct?: number
        }
        Relationships: [
          {
            foreignKeyName: "inventory_items_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_items_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      manager_compensation: {
        Row: {
          basis: string
          company_id: string
          created_at: string
          fixed_amount: number
          mode: string
          percent: number
          profile_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          basis?: string
          company_id: string
          created_at?: string
          fixed_amount?: number
          mode?: string
          percent?: number
          profile_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          basis?: string
          company_id?: string
          created_at?: string
          fixed_amount?: number
          mode?: string
          percent?: number
          profile_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "manager_compensation_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "manager_compensation_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: true
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      modifier_groups: {
        Row: {
          company_id: string
          created_at: string
          display_order: number
          id: string
          is_active: boolean
          max_select: number
          min_select: number
          name: string
          name_ar: string | null
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          max_select?: number
          min_select?: number
          name: string
          name_ar?: string | null
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          max_select?: number
          min_select?: number
          name?: string
          name_ar?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "modifier_groups_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      modifier_option_recipes: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          item_id: string
          option_id: string
          quantity: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          item_id: string
          option_id: string
          quantity: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          item_id?: string
          option_id?: string
          quantity?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "modifier_option_recipes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "modifier_option_recipes_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "modifier_option_recipes_option_id_fkey"
            columns: ["option_id"]
            isOneToOne: false
            referencedRelation: "modifier_options"
            referencedColumns: ["id"]
          },
        ]
      }
      modifier_options: {
        Row: {
          created_at: string
          display_order: number
          group_id: string
          id: string
          is_active: boolean
          name: string
          name_ar: string | null
          price_delta: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          display_order?: number
          group_id: string
          id?: string
          is_active?: boolean
          name: string
          name_ar?: string | null
          price_delta?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          display_order?: number
          group_id?: string
          id?: string
          is_active?: boolean
          name?: string
          name_ar?: string | null
          price_delta?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "modifier_options_group_id_fkey"
            columns: ["group_id"]
            isOneToOne: false
            referencedRelation: "modifier_groups"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          body: string | null
          branch_id: string | null
          company_id: string
          created_at: string
          data: Json | null
          id: string
          read_at: string | null
          required_permission: string | null
          severity: string
          title: string
          type: string
          user_id: string | null
        }
        Insert: {
          body?: string | null
          branch_id?: string | null
          company_id: string
          created_at?: string
          data?: Json | null
          id?: string
          read_at?: string | null
          required_permission?: string | null
          severity?: string
          title: string
          type: string
          user_id?: string | null
        }
        Update: {
          body?: string | null
          branch_id?: string | null
          company_id?: string
          created_at?: string
          data?: Json | null
          id?: string
          read_at?: string | null
          required_permission?: string | null
          severity?: string
          title?: string
          type?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "notifications_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      offer_bundle_items: {
        Row: {
          created_at: string
          id: string
          offer_id: string
          product_id: string
          quantity: number
          size_id: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          offer_id: string
          product_id: string
          quantity?: number
          size_id?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          offer_id?: string
          product_id?: string
          quantity?: number
          size_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "offer_bundle_items_offer_id_fkey"
            columns: ["offer_id"]
            isOneToOne: false
            referencedRelation: "product_offers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offer_bundle_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "offer_bundle_items_size_id_fkey"
            columns: ["size_id"]
            isOneToOne: false
            referencedRelation: "product_sizes"
            referencedColumns: ["id"]
          },
        ]
      }
      order_counters: {
        Row: {
          branch_id: string
          business_date: string
          last_seq: number
        }
        Insert: {
          branch_id: string
          business_date: string
          last_seq?: number
        }
        Update: {
          branch_id?: string
          business_date?: string
          last_seq?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_counters_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
        ]
      }
      order_item_modifiers: {
        Row: {
          created_at: string
          id: string
          name: string
          option_id: string | null
          order_item_id: string
          price_delta: number
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          option_id?: string | null
          order_item_id: string
          price_delta?: number
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          option_id?: string | null
          order_item_id?: string
          price_delta?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_item_modifiers_option_id_fkey"
            columns: ["option_id"]
            isOneToOne: false
            referencedRelation: "modifier_options"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_item_modifiers_order_item_id_fkey"
            columns: ["order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["id"]
          },
        ]
      }
      order_items: {
        Row: {
          base_price: number
          bundle_key: string | null
          created_at: string
          id: string
          line_total: number
          modifiers_total: number
          notes: string | null
          offer_id: string | null
          order_id: string
          product_id: string | null
          product_name: string
          quantity: number
          size_id: string | null
          size_name: string | null
          status: Database["public"]["Enums"]["order_item_status"]
          unit_cost: number
          unit_price: number
          unit_waste_cost: number | null
          void_reason: string | null
        }
        Insert: {
          base_price?: number
          bundle_key?: string | null
          created_at?: string
          id?: string
          line_total?: number
          modifiers_total?: number
          notes?: string | null
          offer_id?: string | null
          order_id: string
          product_id?: string | null
          product_name: string
          quantity?: number
          size_id?: string | null
          size_name?: string | null
          status?: Database["public"]["Enums"]["order_item_status"]
          unit_cost?: number
          unit_price?: number
          unit_waste_cost?: number | null
          void_reason?: string | null
        }
        Update: {
          base_price?: number
          bundle_key?: string | null
          created_at?: string
          id?: string
          line_total?: number
          modifiers_total?: number
          notes?: string | null
          offer_id?: string | null
          order_id?: string
          product_id?: string | null
          product_name?: string
          quantity?: number
          size_id?: string | null
          size_name?: string | null
          status?: Database["public"]["Enums"]["order_item_status"]
          unit_cost?: number
          unit_price?: number
          unit_waste_cost?: number | null
          void_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "order_items_offer_id_fkey"
            columns: ["offer_id"]
            isOneToOne: false
            referencedRelation: "product_offers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_size_id_fkey"
            columns: ["size_id"]
            isOneToOne: false
            referencedRelation: "product_sizes"
            referencedColumns: ["id"]
          },
        ]
      }
      order_payments: {
        Row: {
          amount: number
          created_at: string
          created_by: string | null
          id: string
          method_key: string
          order_id: string
          payment_method_id: string | null
          receiver_number: string | null
          reference: string | null
          sender_number: string | null
        }
        Insert: {
          amount: number
          created_at?: string
          created_by?: string | null
          id?: string
          method_key: string
          order_id: string
          payment_method_id?: string | null
          receiver_number?: string | null
          reference?: string | null
          sender_number?: string | null
        }
        Update: {
          amount?: number
          created_at?: string
          created_by?: string | null
          id?: string
          method_key?: string
          order_id?: string
          payment_method_id?: string | null
          receiver_number?: string | null
          reference?: string | null
          sender_number?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "order_payments_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_payments_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_payments_payment_method_id_fkey"
            columns: ["payment_method_id"]
            isOneToOne: false
            referencedRelation: "payment_methods"
            referencedColumns: ["id"]
          },
        ]
      }
      order_refunds: {
        Row: {
          business_date: string
          amount: number
          blamed_staff_id: string | null
          branch_id: string
          cash_withheld: number
          cashback_done: boolean
          company_id: string
          created_at: string
          created_by: string | null
          fault: string | null
          id: string
          items_payload: Json | null
          kind: string
          method_key: string | null
          order_id: string
          order_item_id: string | null
          origin: string
          reason: string
          reward_clawback: number
          shift_id: string | null
          status: Database["public"]["Enums"]["record_status"]
          tax_amount: number
          wallet_amount: number
        }
        Insert: {
          business_date?: string
          amount: number
          blamed_staff_id?: string | null
          branch_id: string
          cash_withheld?: number
          cashback_done?: boolean
          company_id: string
          created_at?: string
          created_by?: string | null
          fault?: string | null
          id?: string
          items_payload?: Json | null
          kind: string
          method_key?: string | null
          order_id: string
          order_item_id?: string | null
          origin?: string
          reason: string
          reward_clawback?: number
          shift_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          tax_amount?: number
          wallet_amount?: number
        }
        Update: {
          business_date?: string
          amount?: number
          blamed_staff_id?: string | null
          branch_id?: string
          cash_withheld?: number
          cashback_done?: boolean
          company_id?: string
          created_at?: string
          created_by?: string | null
          fault?: string | null
          id?: string
          items_payload?: Json | null
          kind?: string
          method_key?: string | null
          order_id?: string
          order_item_id?: string | null
          origin?: string
          reason?: string
          reward_clawback?: number
          shift_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          tax_amount?: number
          wallet_amount?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_refunds_blamed_staff_id_fkey"
            columns: ["blamed_staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_refunds_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_refunds_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_refunds_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_refunds_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_refunds_order_item_id_fkey"
            columns: ["order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_refunds_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      orders: {
        Row: {
          business_date: string
          branch_id: string
          cancel_reason: string | null
          cancelled_at: string | null
          company_id: string
          completed_at: string | null
          created_at: string
          created_by: string | null
          customer_id: string | null
          customer_name: string | null
          customer_phone: string | null
          discount_amount: number
          discount_reason: string | null
          id: string
          is_soft_opening: boolean
          notes: string | null
          order_number: string
          order_type: Database["public"]["Enums"]["order_type"]
          promotional_discount: number
          shift_id: string | null
          status: Database["public"]["Enums"]["order_status"]
          subtotal: number
          tax_amount: number
          total: number
          updated_at: string
        }
        Insert: {
          business_date?: string
          branch_id: string
          cancel_reason?: string | null
          cancelled_at?: string | null
          company_id: string
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          customer_name?: string | null
          customer_phone?: string | null
          discount_amount?: number
          discount_reason?: string | null
          id?: string
          is_soft_opening?: boolean
          notes?: string | null
          order_number: string
          order_type?: Database["public"]["Enums"]["order_type"]
          promotional_discount?: number
          shift_id?: string | null
          status?: Database["public"]["Enums"]["order_status"]
          subtotal?: number
          tax_amount?: number
          total?: number
          updated_at?: string
        }
        Update: {
          business_date?: string
          branch_id?: string
          cancel_reason?: string | null
          cancelled_at?: string | null
          company_id?: string
          completed_at?: string | null
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          customer_name?: string | null
          customer_phone?: string | null
          discount_amount?: number
          discount_reason?: string | null
          id?: string
          is_soft_opening?: boolean
          notes?: string | null
          order_number?: string
          order_type?: Database["public"]["Enums"]["order_type"]
          promotional_discount?: number
          shift_id?: string | null
          status?: Database["public"]["Enums"]["order_status"]
          subtotal?: number
          tax_amount?: number
          total?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "orders_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_advance_settlements: {
        Row: {
          advance_id: string
          amount: number
          company_id: string
          created_at: string
          distribution_id: string
          id: string
          partner_id: string
          status: Database["public"]["Enums"]["record_status"]
        }
        Insert: {
          advance_id: string
          amount: number
          company_id: string
          created_at?: string
          distribution_id: string
          id?: string
          partner_id: string
          status?: Database["public"]["Enums"]["record_status"]
        }
        Update: {
          advance_id?: string
          amount?: number
          company_id?: string
          created_at?: string
          distribution_id?: string
          id?: string
          partner_id?: string
          status?: Database["public"]["Enums"]["record_status"]
        }
        Relationships: [
          {
            foreignKeyName: "partner_advance_settlements_advance_id_fkey"
            columns: ["advance_id"]
            isOneToOne: false
            referencedRelation: "partner_advances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_advance_settlements_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_advance_settlements_distribution_id_fkey"
            columns: ["distribution_id"]
            isOneToOne: false
            referencedRelation: "profit_distributions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_advance_settlements_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_advance_settlements_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_advance_settlements_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_advances: {
        Row: {
          advance_date: string
          amount: number
          cash_transaction_id: string | null
          company_id: string
          created_at: string
          created_by: string | null
          deducted_amount: number
          id: string
          method: string
          partner_id: string
          reason: string | null
          status: Database["public"]["Enums"]["record_status"]
        }
        Insert: {
          advance_date?: string
          amount: number
          cash_transaction_id?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          deducted_amount?: number
          id?: string
          method?: string
          partner_id: string
          reason?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Update: {
          advance_date?: string
          amount?: number
          cash_transaction_id?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          deducted_amount?: number
          id?: string
          method?: string
          partner_id?: string
          reason?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Relationships: [
          {
            foreignKeyName: "partner_advances_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_advances_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_advances_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_advances_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_capital_contributions: {
        Row: {
          amount: number
          company_id: string
          contribution_date: string
          created_at: string
          created_by: string | null
          currency: string
          effective_from: string
          id: string
          kind: string
          notes: string | null
          partner_id: string
          payment_method: string | null
          reference: string | null
          repaid_amount: number
          reversal_of: string | null
          status: Database["public"]["Enums"]["record_status"]
        }
        Insert: {
          amount: number
          company_id: string
          contribution_date?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          effective_from?: string
          id?: string
          kind?: string
          notes?: string | null
          partner_id: string
          payment_method?: string | null
          reference?: string | null
          repaid_amount?: number
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Update: {
          amount?: number
          company_id?: string
          contribution_date?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          effective_from?: string
          id?: string
          kind?: string
          notes?: string | null
          partner_id?: string
          payment_method?: string | null
          reference?: string | null
          repaid_amount?: number
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Relationships: [
          {
            foreignKeyName: "partner_capital_contributions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_capital_contributions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_capital_contributions_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_capital_contributions_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_capital_contributions_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_capital_contributions_reversal_of_fkey"
            columns: ["reversal_of"]
            isOneToOne: false
            referencedRelation: "partner_capital_contributions"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_dividend_payouts: {
        Row: {
          amount: number
          cash_transaction_id: string | null
          company_id: string
          created_at: string
          created_by: string | null
          distribution_id: string | null
          id: string
          ledger_transaction_id: string | null
          partner_id: string
          period_id: string | null
          status: Database["public"]["Enums"]["record_status"]
        }
        Insert: {
          amount: number
          cash_transaction_id?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          distribution_id?: string | null
          id?: string
          ledger_transaction_id?: string | null
          partner_id: string
          period_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Update: {
          amount?: number
          cash_transaction_id?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          distribution_id?: string | null
          id?: string
          ledger_transaction_id?: string | null
          partner_id?: string
          period_id?: string | null
          status?: Database["public"]["Enums"]["record_status"]
        }
        Relationships: [
          {
            foreignKeyName: "partner_dividend_payouts_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_dividend_payouts_distribution_id_fkey"
            columns: ["distribution_id"]
            isOneToOne: false
            referencedRelation: "profit_distributions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_dividend_payouts_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_dividend_payouts_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_dividend_payouts_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_dividend_payouts_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "accounting_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_ledger_transactions: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          created_by: string | null
          currency: string
          description: string | null
          id: string
          partner_id: string
          reference_id: string | null
          reference_type: string | null
          reversal_of: string | null
          status: Database["public"]["Enums"]["record_status"]
          transaction_date: string
          transaction_type: Database["public"]["Enums"]["ledger_txn_type"]
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          id?: string
          partner_id: string
          reference_id?: string | null
          reference_type?: string | null
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          transaction_date?: string
          transaction_type: Database["public"]["Enums"]["ledger_txn_type"]
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          id?: string
          partner_id?: string
          reference_id?: string | null
          reference_type?: string | null
          reversal_of?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          transaction_date?: string
          transaction_type?: Database["public"]["Enums"]["ledger_txn_type"]
        }
        Relationships: [
          {
            foreignKeyName: "partner_ledger_transactions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_ledger_transactions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_ledger_transactions_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_ledger_transactions_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_ledger_transactions_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_ledger_transactions_reversal_of_fkey"
            columns: ["reversal_of"]
            isOneToOne: false
            referencedRelation: "partner_ledger_transactions"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_liquidations: {
        Row: {
          cash_account_id: string | null
          cash_transaction_id: string | null
          company_id: string
          created_at: string
          final_balance: number
          id: string
          notes: string | null
          partner_id: string
          performed_by: string | null
          redistribution: Json
          settlement_method: string
        }
        Insert: {
          cash_account_id?: string | null
          cash_transaction_id?: string | null
          company_id: string
          created_at?: string
          final_balance: number
          id?: string
          notes?: string | null
          partner_id: string
          performed_by?: string | null
          redistribution?: Json
          settlement_method: string
        }
        Update: {
          cash_account_id?: string | null
          cash_transaction_id?: string | null
          company_id?: string
          created_at?: string
          final_balance?: number
          id?: string
          notes?: string | null
          partner_id?: string
          performed_by?: string | null
          redistribution?: Json
          settlement_method?: string
        }
        Relationships: [
          {
            foreignKeyName: "partner_liquidations_cash_account_id_fkey"
            columns: ["cash_account_id"]
            isOneToOne: false
            referencedRelation: "cash_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_liquidations_cash_transaction_id_fkey"
            columns: ["cash_transaction_id"]
            isOneToOne: false
            referencedRelation: "cash_transactions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_liquidations_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_liquidations_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_liquidations_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_liquidations_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_liquidations_performed_by_fkey"
            columns: ["performed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_period_freezes: {
        Row: {
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          partner_id: string
          period_id: string
          reason: string | null
        }
        Insert: {
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          partner_id: string
          period_id: string
          reason?: string | null
        }
        Update: {
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          partner_id?: string
          period_id?: string
          reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "partner_period_freezes_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_period_freezes_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_period_freezes_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_period_freezes_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_period_freezes_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "accounting_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_tab_orders: {
        Row: {
          branch_id: string | null
          company_id: string
          created_at: string
          created_by: string | null
          distribution_id: string | null
          id: string
          is_settled: boolean
          order_id: string
          partner_id: string
          settled_amount: number
          settled_at: string | null
          total_amount: number
          updated_at: string
        }
        Insert: {
          branch_id?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          distribution_id?: string | null
          id?: string
          is_settled?: boolean
          order_id: string
          partner_id: string
          settled_amount?: number
          settled_at?: string | null
          total_amount: number
          updated_at?: string
        }
        Update: {
          branch_id?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          distribution_id?: string | null
          id?: string
          is_settled?: boolean
          order_id?: string
          partner_id?: string
          settled_amount?: number
          settled_at?: string | null
          total_amount?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "partner_tab_orders_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_orders_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_orders_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_orders_distribution_id_fkey"
            columns: ["distribution_id"]
            isOneToOne: false
            referencedRelation: "profit_distributions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_orders_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: true
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_orders_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_tab_orders_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_tab_orders_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_tab_settlements: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          distribution_id: string
          id: string
          partner_id: string
          status: Database["public"]["Enums"]["record_status"]
          tab_order_id: string
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          distribution_id: string
          id?: string
          partner_id: string
          status?: Database["public"]["Enums"]["record_status"]
          tab_order_id: string
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          distribution_id?: string
          id?: string
          partner_id?: string
          status?: Database["public"]["Enums"]["record_status"]
          tab_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "partner_tab_settlements_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_settlements_distribution_id_fkey"
            columns: ["distribution_id"]
            isOneToOne: false
            referencedRelation: "profit_distributions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_settlements_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_tab_settlements_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_tab_settlements_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_tab_settlements_tab_order_id_fkey"
            columns: ["tab_order_id"]
            isOneToOne: false
            referencedRelation: "partner_tab_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_withdrawal_requests: {
        Row: {
          amount: number
          cash_transaction_id: string | null
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          ledger_transaction_id: string | null
          method: string
          notes: string | null
          partner_id: string
          review_note: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          updated_at: string
        }
        Insert: {
          amount: number
          cash_transaction_id?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          ledger_transaction_id?: string | null
          method?: string
          notes?: string | null
          partner_id: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          amount?: number
          cash_transaction_id?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          ledger_transaction_id?: string | null
          method?: string
          notes?: string | null
          partner_id?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "partner_withdrawal_requests_cash_transaction_id_fkey"
            columns: ["cash_transaction_id"]
            isOneToOne: false
            referencedRelation: "cash_transactions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_ledger_transaction_id_fkey"
            columns: ["ledger_transaction_id"]
            isOneToOne: false
            referencedRelation: "partner_ledger_transactions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partner_withdrawal_requests_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      partners: {
        Row: {
          company_id: string
          created_at: string
          created_by: string | null
          customer_id: string | null
          dividends_paused: boolean
          email: string | null
          id: string
          is_managing_staff: boolean
          management_salary_pct: number
          management_salary_type: string
          name: string
          notes: string | null
          phone: string | null
          profit_share_percentage: number | null
          status: Database["public"]["Enums"]["partner_status"]
          tier: string
          updated_at: string
          user_id: string | null
        }
        Insert: {
          company_id: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          dividends_paused?: boolean
          email?: string | null
          id?: string
          is_managing_staff?: boolean
          management_salary_pct?: number
          management_salary_type?: string
          name: string
          notes?: string | null
          phone?: string | null
          profit_share_percentage?: number | null
          status?: Database["public"]["Enums"]["partner_status"]
          tier?: string
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          company_id?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          dividends_paused?: boolean
          email?: string | null
          id?: string
          is_managing_staff?: boolean
          management_salary_pct?: number
          management_salary_type?: string
          name?: string
          notes?: string | null
          phone?: string | null
          profit_share_percentage?: number | null
          status?: Database["public"]["Enums"]["partner_status"]
          tier?: string
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "partners_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partners_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partners_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "partners_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_methods: {
        Row: {
          company_id: string
          created_at: string
          id: string
          is_active: boolean
          key: string
          kind: string
          name: string
          provider: string | null
          requires_receiver_number: boolean
          requires_reference: boolean
          requires_sender_number: boolean
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          id?: string
          is_active?: boolean
          key: string
          kind: string
          name: string
          provider?: string | null
          requires_receiver_number?: boolean
          requires_reference?: boolean
          requires_sender_number?: boolean
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          id?: string
          is_active?: boolean
          key?: string
          kind?: string
          name?: string
          provider?: string | null
          requires_receiver_number?: boolean
          requires_reference?: boolean
          requires_sender_number?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_methods_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_deductions: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          id: string
          salary_payment_id: string
          source_id: string
          source_type: string
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          id?: string
          salary_payment_id: string
          source_id: string
          source_type: string
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          id?: string
          salary_payment_id?: string
          source_id?: string
          source_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_deductions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_deductions_salary_payment_id_fkey"
            columns: ["salary_payment_id"]
            isOneToOne: false
            referencedRelation: "salary_payments"
            referencedColumns: ["id"]
          },
        ]
      }
      period_partner_shares: {
        Row: {
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          ownership_percentage: number
          partner_id: string
          period_id: string
        }
        Insert: {
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          ownership_percentage: number
          partner_id: string
          period_id: string
        }
        Update: {
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          ownership_percentage?: number
          partner_id?: string
          period_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "period_partner_shares_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "period_partner_shares_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "period_partner_shares_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "period_partner_shares_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "period_partner_shares_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "period_partner_shares_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "accounting_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      permissions: {
        Row: {
          created_at: string
          description: string | null
          id: string
          key: string
          module: string
          name: string
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          key: string
          module: string
          name: string
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          key?: string
          module?: string
          name?: string
        }
        Relationships: []
      }
      product_branch_settings: {
        Row: {
          branch_id: string
          created_at: string
          id: string
          is_available: boolean
          price_override: number | null
          product_id: string
          updated_at: string
        }
        Insert: {
          branch_id: string
          created_at?: string
          id?: string
          is_available?: boolean
          price_override?: number | null
          product_id: string
          updated_at?: string
        }
        Update: {
          branch_id?: string
          created_at?: string
          id?: string
          is_available?: boolean
          price_override?: number | null
          product_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_branch_settings_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_branch_settings_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      product_modifier_groups: {
        Row: {
          created_at: string
          group_id: string
          product_id: string
        }
        Insert: {
          created_at?: string
          group_id: string
          product_id: string
        }
        Update: {
          created_at?: string
          group_id?: string
          product_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_modifier_groups_group_id_fkey"
            columns: ["group_id"]
            isOneToOne: false
            referencedRelation: "modifier_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_modifier_groups_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      product_offers: {
        Row: {
          base_price_snapshot: number
          company_id: string
          created_at: string
          created_by: string | null
          double_points: boolean
          ends_at: string | null
          id: string
          image_path: string | null
          is_active: boolean
          notes: string | null
          offer_price: number
          offer_type: string
          product_id: string | null
          starts_at: string
          title: string
          unit_cost_snapshot: number
          updated_at: string
        }
        Insert: {
          base_price_snapshot?: number
          company_id: string
          created_at?: string
          created_by?: string | null
          double_points?: boolean
          ends_at?: string | null
          id?: string
          image_path?: string | null
          is_active?: boolean
          notes?: string | null
          offer_price: number
          offer_type?: string
          product_id?: string | null
          starts_at?: string
          title: string
          unit_cost_snapshot?: number
          updated_at?: string
        }
        Update: {
          base_price_snapshot?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          double_points?: boolean
          ends_at?: string | null
          id?: string
          image_path?: string | null
          is_active?: boolean
          notes?: string | null
          offer_price?: number
          offer_type?: string
          product_id?: string | null
          starts_at?: string
          title?: string
          unit_cost_snapshot?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_offers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_offers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_offers_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      product_recipes: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          item_id: string
          product_id: string
          quantity: number
          size_id: string | null
          unit: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          item_id: string
          product_id: string
          quantity: number
          size_id?: string | null
          unit?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          item_id?: string
          product_id?: string
          quantity?: number
          size_id?: string | null
          unit?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_recipes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_recipes_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_recipes_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_recipes_size_id_fkey"
            columns: ["size_id"]
            isOneToOne: false
            referencedRelation: "product_sizes"
            referencedColumns: ["id"]
          },
        ]
      }
      product_sizes: {
        Row: {
          created_at: string
          display_order: number
          id: string
          is_active: boolean
          is_default: boolean
          name: string
          name_ar: string | null
          price_delta: number
          product_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          is_default?: boolean
          name: string
          name_ar?: string | null
          price_delta?: number
          product_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          is_default?: boolean
          name?: string
          name_ar?: string | null
          price_delta?: number
          product_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_sizes_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          base_price: number
          category_id: string | null
          company_id: string
          cost: number
          created_at: string
          created_by: string | null
          description: string | null
          display_order: number
          id: string
          image_url: string | null
          is_active: boolean
          is_available: boolean
          is_taxable: boolean
          name: string
          name_ar: string | null
          show_on_public_menu: boolean
          sku: string | null
          track_stock: boolean
          updated_at: string
        }
        Insert: {
          base_price?: number
          category_id?: string | null
          company_id: string
          cost?: number
          created_at?: string
          created_by?: string | null
          description?: string | null
          display_order?: number
          id?: string
          image_url?: string | null
          is_active?: boolean
          is_available?: boolean
          is_taxable?: boolean
          name: string
          name_ar?: string | null
          show_on_public_menu?: boolean
          sku?: string | null
          track_stock?: boolean
          updated_at?: string
        }
        Update: {
          base_price?: number
          category_id?: string | null
          company_id?: string
          cost?: number
          created_at?: string
          created_by?: string | null
          description?: string | null
          display_order?: number
          id?: string
          image_url?: string | null
          is_active?: boolean
          is_available?: boolean
          is_taxable?: boolean
          name?: string
          name_ar?: string | null
          show_on_public_menu?: boolean
          sku?: string | null
          track_stock?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "products_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      profit_distribution_lines: {
        Row: {
          amount: number
          created_at: string
          distribution_id: string
          id: string
          ledger_transaction_id: string | null
          ownership_percentage: number
          partner_id: string
        }
        Insert: {
          amount: number
          created_at?: string
          distribution_id: string
          id?: string
          ledger_transaction_id?: string | null
          ownership_percentage: number
          partner_id: string
        }
        Update: {
          amount?: number
          created_at?: string
          distribution_id?: string
          id?: string
          ledger_transaction_id?: string | null
          ownership_percentage?: number
          partner_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "profit_distribution_lines_distribution_id_fkey"
            columns: ["distribution_id"]
            isOneToOne: false
            referencedRelation: "profit_distributions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profit_distribution_lines_ledger_transaction_id_fkey"
            columns: ["ledger_transaction_id"]
            isOneToOne: false
            referencedRelation: "partner_ledger_transactions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profit_distribution_lines_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_balances"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "profit_distribution_lines_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partner_ownership"
            referencedColumns: ["partner_id"]
          },
          {
            foreignKeyName: "profit_distribution_lines_partner_id_fkey"
            columns: ["partner_id"]
            isOneToOne: false
            referencedRelation: "partners"
            referencedColumns: ["id"]
          },
        ]
      }
      profit_distributions: {
        Row: {
          company_id: string
          created_at: string
          created_by: string | null
          currency: string
          development_fund_amount: number
          distributed_at: string | null
          id: string
          management_salary: number
          net_profit: number
          notes: string | null
          period_id: string | null
          pnl_snapshot: Json | null
          range_from: string | null
          range_to: string | null
          reserve_amount: number
          reverse_reason: string | null
          reversed_at: string | null
          reversed_by: string | null
          status: Database["public"]["Enums"]["record_status"]
          tab_deducted: number
        }
        Insert: {
          company_id: string
          created_at?: string
          created_by?: string | null
          currency?: string
          development_fund_amount?: number
          distributed_at?: string | null
          id?: string
          management_salary?: number
          net_profit?: number
          notes?: string | null
          period_id?: string | null
          pnl_snapshot?: Json | null
          range_from?: string | null
          range_to?: string | null
          reserve_amount?: number
          reverse_reason?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          tab_deducted?: number
        }
        Update: {
          company_id?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          development_fund_amount?: number
          distributed_at?: string | null
          id?: string
          management_salary?: number
          net_profit?: number
          notes?: string | null
          period_id?: string | null
          pnl_snapshot?: Json | null
          range_from?: string | null
          range_to?: string | null
          reserve_amount?: number
          reverse_reason?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          status?: Database["public"]["Enums"]["record_status"]
          tab_deducted?: number
        }
        Relationships: [
          {
            foreignKeyName: "profit_distributions_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profit_distributions_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profit_distributions_period_id_fkey"
            columns: ["period_id"]
            isOneToOne: false
            referencedRelation: "accounting_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_items: {
        Row: {
          created_at: string
          id: string
          item_id: string
          line_total: number
          purchase_id: string
          quantity: number
          unit_cost: number
        }
        Insert: {
          created_at?: string
          id?: string
          item_id: string
          line_total?: number
          purchase_id: string
          quantity: number
          unit_cost: number
        }
        Update: {
          created_at?: string
          id?: string
          item_id?: string
          line_total?: number
          purchase_id?: string
          quantity?: number
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "purchase_items_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_items_purchase_id_fkey"
            columns: ["purchase_id"]
            isOneToOne: false
            referencedRelation: "purchases"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_payments: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          method: string | null
          notes: string | null
          paid_at: string
          purchase_id: string
          shift_id: string | null
          source: string
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          method?: string | null
          notes?: string | null
          paid_at?: string
          purchase_id: string
          shift_id?: string | null
          source?: string
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          method?: string | null
          notes?: string | null
          paid_at?: string
          purchase_id?: string
          shift_id?: string | null
          source?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_payments_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_payments_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_payments_purchase_id_fkey"
            columns: ["purchase_id"]
            isOneToOne: false
            referencedRelation: "purchases"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_payments_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_return_items: {
        Row: {
          created_at: string
          id: string
          item_id: string
          line_total: number
          purchase_item_id: string
          quantity: number
          return_id: string
          unit_cost: number
        }
        Insert: {
          created_at?: string
          id?: string
          item_id: string
          line_total?: number
          purchase_item_id: string
          quantity: number
          return_id: string
          unit_cost?: number
        }
        Update: {
          created_at?: string
          id?: string
          item_id?: string
          line_total?: number
          purchase_item_id?: string
          quantity?: number
          return_id?: string
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "purchase_return_items_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_return_items_purchase_item_id_fkey"
            columns: ["purchase_item_id"]
            isOneToOne: false
            referencedRelation: "purchase_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_return_items_return_id_fkey"
            columns: ["return_id"]
            isOneToOne: false
            referencedRelation: "purchase_returns"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_returns: {
        Row: {
          branch_id: string
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          purchase_id: string
          reason: string
          refund_mode: string
          return_date: string
          total: number
        }
        Insert: {
          branch_id: string
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          purchase_id: string
          reason: string
          refund_mode?: string
          return_date?: string
          total?: number
        }
        Update: {
          branch_id?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          purchase_id?: string
          reason?: string
          refund_mode?: string
          return_date?: string
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "purchase_returns_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_returns_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_returns_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_returns_purchase_id_fkey"
            columns: ["purchase_id"]
            isOneToOne: false
            referencedRelation: "purchases"
            referencedColumns: ["id"]
          },
        ]
      }
      purchases: {
        Row: {
          attachment_path: string | null
          branch_id: string
          cancel_reason: string | null
          company_id: string
          created_at: string
          created_by: string | null
          discount_amount: number
          id: string
          invoice_number: string | null
          notes: string | null
          paid_amount: number
          payment_method: string | null
          payment_terms: string
          purchase_date: string
          received_at: string | null
          received_by: string | null
          returned_amount: number
          status: Database["public"]["Enums"]["purchase_status"]
          subtotal: number
          supplier_id: string | null
          tax_amount: number
          total: number
          updated_at: string
        }
        Insert: {
          attachment_path?: string | null
          branch_id: string
          cancel_reason?: string | null
          company_id: string
          created_at?: string
          created_by?: string | null
          discount_amount?: number
          id?: string
          invoice_number?: string | null
          notes?: string | null
          paid_amount?: number
          payment_method?: string | null
          payment_terms?: string
          purchase_date?: string
          received_at?: string | null
          received_by?: string | null
          returned_amount?: number
          status?: Database["public"]["Enums"]["purchase_status"]
          subtotal?: number
          supplier_id?: string | null
          tax_amount?: number
          total?: number
          updated_at?: string
        }
        Update: {
          attachment_path?: string | null
          branch_id?: string
          cancel_reason?: string | null
          company_id?: string
          created_at?: string
          created_by?: string | null
          discount_amount?: number
          id?: string
          invoice_number?: string | null
          notes?: string | null
          paid_amount?: number
          payment_method?: string | null
          payment_terms?: string
          purchase_date?: string
          received_at?: string | null
          received_by?: string | null
          returned_amount?: number
          status?: Database["public"]["Enums"]["purchase_status"]
          subtotal?: number
          supplier_id?: string | null
          tax_amount?: number
          total?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchases_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_received_by_fkey"
            columns: ["received_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchases_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      role_permissions: {
        Row: {
          created_at: string
          permission_id: string
          role_id: string
        }
        Insert: {
          created_at?: string
          permission_id: string
          role_id: string
        }
        Update: {
          created_at?: string
          permission_id?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "role_permissions_permission_id_fkey"
            columns: ["permission_id"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
        ]
      }
      roles: {
        Row: {
          company_id: string
          created_at: string
          description: string | null
          id: string
          is_system_role: boolean
          key: string | null
          name: string
          updated_at: string
        }
        Insert: {
          company_id: string
          created_at?: string
          description?: string | null
          id?: string
          is_system_role?: boolean
          key?: string | null
          name: string
          updated_at?: string
        }
        Update: {
          company_id?: string
          created_at?: string
          description?: string | null
          id?: string
          is_system_role?: boolean
          key?: string | null
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "roles_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      salary_payments: {
        Row: {
          absence_deduction: number
          accounting_period_id: string | null
          advance_deduction: number
          base_amount: number
          bonus: number
          company_id: string
          created_at: string
          created_by: string | null
          deduction: number
          id: string
          net_amount: number
          notes: string | null
          paid_at: string | null
          paid_by: string | null
          penalty_deduction: number
          period_end: string
          period_start: string
          salary_kind: string
          status: Database["public"]["Enums"]["record_status"]
          updated_at: string
          user_id: string
        }
        Insert: {
          absence_deduction?: number
          accounting_period_id?: string | null
          advance_deduction?: number
          base_amount?: number
          bonus?: number
          company_id: string
          created_at?: string
          created_by?: string | null
          deduction?: number
          id?: string
          net_amount?: number
          notes?: string | null
          paid_at?: string | null
          paid_by?: string | null
          penalty_deduction?: number
          period_end: string
          period_start: string
          salary_kind?: string
          status?: Database["public"]["Enums"]["record_status"]
          updated_at?: string
          user_id: string
        }
        Update: {
          absence_deduction?: number
          accounting_period_id?: string | null
          advance_deduction?: number
          base_amount?: number
          bonus?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          deduction?: number
          id?: string
          net_amount?: number
          notes?: string | null
          paid_at?: string | null
          paid_by?: string | null
          penalty_deduction?: number
          period_end?: string
          period_start?: string
          salary_kind?: string
          status?: Database["public"]["Enums"]["record_status"]
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "salary_payments_accounting_period_id_fkey"
            columns: ["accounting_period_id"]
            isOneToOne: false
            referencedRelation: "accounting_periods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_payments_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_payments_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_payments_paid_by_fkey"
            columns: ["paid_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "salary_payments_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      shift_policies: {
        Row: {
          auto_close: boolean
          company_id: string
          created_at: string
          id: string
          open_grace_minutes: number
          updated_at: string
          warn_minutes: number
        }
        Insert: {
          auto_close?: boolean
          company_id: string
          created_at?: string
          id?: string
          open_grace_minutes?: number
          updated_at?: string
          warn_minutes?: number
        }
        Update: {
          auto_close?: boolean
          company_id?: string
          created_at?: string
          id?: string
          open_grace_minutes?: number
          updated_at?: string
          warn_minutes?: number
        }
        Relationships: [
          {
            foreignKeyName: "shift_policies_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: true
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      shift_staff: {
        Row: {
          added_by: string | null
          company_id: string
          created_at: string
          shift_id: string
          staff_id: string
        }
        Insert: {
          added_by?: string | null
          company_id: string
          created_at?: string
          shift_id: string
          staff_id: string
        }
        Update: {
          added_by?: string | null
          company_id?: string
          created_at?: string
          shift_id?: string
          staff_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shift_staff_added_by_fkey"
            columns: ["added_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_staff_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_staff_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_staff_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      shifts: {
        Row: {
          business_date: string
          branch_id: string
          cash_drop: number | null
          closed_at: string | null
          closed_by: string | null
          closing_cash: number | null
          company_id: string
          created_at: string
          expected_cash: number | null
          id: string
          notes: string | null
          opened_at: string
          opening_cash: number
          retained_float: number | null
          shift_expenses: number
          shortage_resolution: string | null
          shortage_staff_id: string | null
          status: Database["public"]["Enums"]["shift_status"]
          updated_at: string
          user_id: string
          variance: number | null
        }
        Insert: {
          business_date?: string
          branch_id: string
          cash_drop?: number | null
          closed_at?: string | null
          closed_by?: string | null
          closing_cash?: number | null
          company_id: string
          created_at?: string
          expected_cash?: number | null
          id?: string
          notes?: string | null
          opened_at?: string
          opening_cash?: number
          retained_float?: number | null
          shift_expenses?: number
          shortage_resolution?: string | null
          shortage_staff_id?: string | null
          status?: Database["public"]["Enums"]["shift_status"]
          updated_at?: string
          user_id: string
          variance?: number | null
        }
        Update: {
          business_date?: string
          branch_id?: string
          cash_drop?: number | null
          closed_at?: string | null
          closed_by?: string | null
          closing_cash?: number | null
          company_id?: string
          created_at?: string
          expected_cash?: number | null
          id?: string
          notes?: string | null
          opened_at?: string
          opening_cash?: number
          retained_float?: number | null
          shift_expenses?: number
          shortage_resolution?: string | null
          shortage_staff_id?: string | null
          status?: Database["public"]["Enums"]["shift_status"]
          updated_at?: string
          user_id?: string
          variance?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "shifts_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_closed_by_fkey"
            columns: ["closed_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_shortage_staff_id_fkey"
            columns: ["shortage_staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      soft_opening_categories: {
        Row: {
          created_at: string
          display_order: number
          id: string
          is_active: boolean
          name_ar: string
          name_en: string
          slug: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          name_ar: string
          name_en: string
          slug: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          name_ar?: string
          name_en?: string
          slug?: string
          updated_at?: string
        }
        Relationships: []
      }
      soft_opening_item_addons: {
        Row: {
          created_at: string
          display_order: number
          id: string
          is_active: boolean
          item_id: string
          key: string
          name_ar: string
          name_en: string
          price: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          item_id: string
          key: string
          name_ar: string
          name_en: string
          price?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          item_id?: string
          key?: string
          name_ar?: string
          name_en?: string
          price?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "soft_opening_item_addons_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "soft_opening_items"
            referencedColumns: ["id"]
          },
        ]
      }
      soft_opening_item_variants: {
        Row: {
          created_at: string
          display_order: number
          id: string
          is_active: boolean
          item_id: string
          key: string
          name_ar: string
          name_en: string
          price: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          item_id: string
          key: string
          name_ar: string
          name_en: string
          price: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          display_order?: number
          id?: string
          is_active?: boolean
          item_id?: string
          key?: string
          name_ar?: string
          name_en?: string
          price?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "soft_opening_item_variants_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "soft_opening_items"
            referencedColumns: ["id"]
          },
        ]
      }
      soft_opening_items: {
        Row: {
          category_id: string
          created_at: string
          display_order: number
          id: string
          image_key: string
          is_active: boolean
          is_available: boolean
          name_ar: string
          name_en: string
          price: number
          serve_type: string
          slug: string
          updated_at: string
        }
        Insert: {
          category_id: string
          created_at?: string
          display_order?: number
          id?: string
          image_key: string
          is_active?: boolean
          is_available?: boolean
          name_ar: string
          name_en: string
          price: number
          serve_type?: string
          slug: string
          updated_at?: string
        }
        Update: {
          category_id?: string
          created_at?: string
          display_order?: number
          id?: string
          image_key?: string
          is_active?: boolean
          is_available?: boolean
          name_ar?: string
          name_en?: string
          price?: number
          serve_type?: string
          slug?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "soft_opening_items_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "soft_opening_categories"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_bonuses: {
        Row: {
          amount: number
          bonus_date: string
          company_id: string
          created_at: string
          created_by: string | null
          id: string
          is_settled: boolean
          payroll_id: string | null
          reason: string
          staff_id: string
        }
        Insert: {
          amount: number
          bonus_date?: string
          company_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_settled?: boolean
          payroll_id?: string | null
          reason: string
          staff_id: string
        }
        Update: {
          amount?: number
          bonus_date?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_settled?: boolean
          payroll_id?: string | null
          reason?: string
          staff_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_bonuses_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_bonuses_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_bonuses_payroll_id_fkey"
            columns: ["payroll_id"]
            isOneToOne: false
            referencedRelation: "salary_payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_bonuses_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_penalties: {
        Row: {
          amount: number
          company_id: string
          created_at: string
          created_by: string | null
          deducted_amount: number
          id: string
          is_settled: boolean
          order_id: string | null
          payroll_id: string | null
          reason: string
          shift_id: string | null
          source: string | null
          staff_id: string
          stock_movement_id: string | null
        }
        Insert: {
          amount: number
          company_id: string
          created_at?: string
          created_by?: string | null
          deducted_amount?: number
          id?: string
          is_settled?: boolean
          order_id?: string | null
          payroll_id?: string | null
          reason: string
          shift_id?: string | null
          source?: string | null
          staff_id: string
          stock_movement_id?: string | null
        }
        Update: {
          amount?: number
          company_id?: string
          created_at?: string
          created_by?: string | null
          deducted_amount?: number
          id?: string
          is_settled?: boolean
          order_id?: string | null
          payroll_id?: string | null
          reason?: string
          shift_id?: string | null
          source?: string | null
          staff_id?: string
          stock_movement_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "staff_penalties_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_penalties_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_penalties_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_penalties_payroll_id_fkey"
            columns: ["payroll_id"]
            isOneToOne: false
            referencedRelation: "salary_payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_penalties_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_penalties_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_penalties_stock_movement_id_fkey"
            columns: ["stock_movement_id"]
            isOneToOne: false
            referencedRelation: "stock_movements"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_movements: {
        Row: {
          business_date: string
          balance_after: number
          branch_id: string
          company_id: string
          cost_event: boolean
          created_at: string
          created_by: string | null
          id: string
          item_id: string
          location: string
          movement_type: Database["public"]["Enums"]["stock_movement_type"]
          quantity: number
          reason: string | null
          reference_id: string | null
          reference_type: string | null
          unit_cost: number
          waste_bearer: string | null
          waste_staff_id: string | null
        }
        Insert: {
          business_date?: string
          balance_after?: number
          branch_id: string
          company_id: string
          cost_event?: boolean
          created_at?: string
          created_by?: string | null
          id?: string
          item_id: string
          location?: string
          movement_type: Database["public"]["Enums"]["stock_movement_type"]
          quantity: number
          reason?: string | null
          reference_id?: string | null
          reference_type?: string | null
          unit_cost?: number
          waste_bearer?: string | null
          waste_staff_id?: string | null
        }
        Update: {
          business_date?: string
          balance_after?: number
          branch_id?: string
          company_id?: string
          cost_event?: boolean
          created_at?: string
          created_by?: string | null
          id?: string
          item_id?: string
          location?: string
          movement_type?: Database["public"]["Enums"]["stock_movement_type"]
          quantity?: number
          reason?: string | null
          reference_id?: string | null
          reference_type?: string | null
          unit_cost?: number
          waste_bearer?: string | null
          waste_staff_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_waste_staff_id_fkey"
            columns: ["waste_staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_overrides: {
        Row: {
          branch_id: string
          company_id: string
          created_at: string
          expires_at: string
          id: string
          items: Json
          profile_id: string
          reason: string | null
        }
        Insert: {
          branch_id: string
          company_id: string
          created_at?: string
          expires_at: string
          id?: string
          items?: Json
          profile_id: string
          reason?: string | null
        }
        Update: {
          branch_id?: string
          company_id?: string
          created_at?: string
          expires_at?: string
          id?: string
          items?: Json
          profile_id?: string
          reason?: string | null
        }
        Relationships: []
      }
      stock_transfer_items: {
        Row: {
          id: string
          item_id: string
          quantity: number
          transfer_id: string
        }
        Insert: {
          id?: string
          item_id: string
          quantity: number
          transfer_id: string
        }
        Update: {
          id?: string
          item_id?: string
          quantity?: number
          transfer_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_transfer_items_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfer_items_transfer_id_fkey"
            columns: ["transfer_id"]
            isOneToOne: false
            referencedRelation: "stock_transfers"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_transfers: {
        Row: {
          branch_id: string
          company_id: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          id: string
          notes: string | null
          reject_reason: string | null
          requested_by: string | null
          status: string
          updated_at: string
        }
        Insert: {
          branch_id: string
          company_id: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          notes?: string | null
          reject_reason?: string | null
          requested_by?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          branch_id?: string
          company_id?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          id?: string
          notes?: string | null
          reject_reason?: string | null
          requested_by?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "stock_transfers_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_transfers_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      stocktake_lines: {
        Row: {
          allowance: number
          counted: number
          expected: number
          id: string
          item_id: string
          location: string
          net_variance: number
          stocktake_id: string
          unit_cost: number
          variance: number
        }
        Insert: {
          allowance?: number
          counted: number
          expected: number
          id?: string
          item_id: string
          location: string
          net_variance: number
          stocktake_id: string
          unit_cost?: number
          variance: number
        }
        Update: {
          allowance?: number
          counted?: number
          expected?: number
          id?: string
          item_id?: string
          location?: string
          net_variance?: number
          stocktake_id?: string
          unit_cost?: number
          variance?: number
        }
        Relationships: [
          {
            foreignKeyName: "stocktake_lines_item_id_fkey"
            columns: ["item_id"]
            isOneToOne: false
            referencedRelation: "inventory_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_stocktake_id_fkey"
            columns: ["stocktake_id"]
            isOneToOne: false
            referencedRelation: "stocktakes"
            referencedColumns: ["id"]
          },
        ]
      }
      stocktakes: {
        Row: {
          branch_id: string
          company_id: string
          created_at: string
          created_by: string | null
          hr_waste_credit: number
          id: string
          notes: string | null
          scope: string
          settle_shift_id: string | null
          settle_staff_id: string | null
          settlement: string | null
          shortage_cost: number
        }
        Insert: {
          branch_id: string
          company_id: string
          created_at?: string
          created_by?: string | null
          hr_waste_credit?: number
          id?: string
          notes?: string | null
          scope: string
          settle_shift_id?: string | null
          settle_staff_id?: string | null
          settlement?: string | null
          shortage_cost?: number
        }
        Update: {
          branch_id?: string
          company_id?: string
          created_at?: string
          created_by?: string | null
          hr_waste_credit?: number
          id?: string
          notes?: string | null
          scope?: string
          settle_shift_id?: string | null
          settle_staff_id?: string | null
          settlement?: string | null
          shortage_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "stocktakes_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktakes_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktakes_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktakes_settle_shift_id_fkey"
            columns: ["settle_shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktakes_settle_staff_id_fkey"
            columns: ["settle_staff_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      suppliers: {
        Row: {
          address: string | null
          company_id: string
          contact_person: string | null
          created_at: string
          created_by: string | null
          email: string | null
          id: string
          is_active: boolean
          name: string
          notes: string | null
          payment_terms: string | null
          phone: string | null
          updated_at: string
        }
        Insert: {
          address?: string | null
          company_id: string
          contact_person?: string | null
          created_at?: string
          created_by?: string | null
          email?: string | null
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          payment_terms?: string | null
          phone?: string | null
          updated_at?: string
        }
        Update: {
          address?: string | null
          company_id?: string
          contact_person?: string | null
          created_at?: string
          created_by?: string | null
          email?: string | null
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          payment_terms?: string | null
          phone?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "suppliers_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "suppliers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_branches: {
        Row: {
          branch_id: string
          created_at: string
          id: string
          is_default: boolean
          user_id: string
        }
        Insert: {
          branch_id: string
          created_at?: string
          id?: string
          is_default?: boolean
          user_id: string
        }
        Update: {
          branch_id?: string
          created_at?: string
          id?: string
          is_default?: boolean
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_branches_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_branches_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_documents: {
        Row: {
          company_id: string
          created_at: string
          created_by: string | null
          file_path: string
          id: string
          kind: string
          mime_type: string | null
          user_id: string
        }
        Insert: {
          company_id: string
          created_at?: string
          created_by?: string | null
          file_path: string
          id?: string
          kind: string
          mime_type?: string | null
          user_id: string
        }
        Update: {
          company_id?: string
          created_at?: string
          created_by?: string | null
          file_path?: string
          id?: string
          kind?: string
          mime_type?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_documents_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_documents_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_documents_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_nav_overrides: {
        Row: {
          company_id: string
          path: string
          profile_id: string
          updated_at: string
          updated_by: string | null
          visible: boolean
        }
        Insert: {
          company_id: string
          path: string
          profile_id: string
          updated_at?: string
          updated_by?: string | null
          visible: boolean
        }
        Update: {
          company_id?: string
          path?: string
          profile_id?: string
          updated_at?: string
          updated_by?: string | null
          visible?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "user_nav_overrides_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_nav_overrides_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_profiles: {
        Row: {
          archived_at: string | null
          auth_user_id: string | null
          avatar_url: string | null
          company_id: string
          created_at: string
          display_name: string | null
          email: string | null
          employee_code: string | null
          first_name: string
          hire_date: string | null
          id: string
          is_active: boolean
          is_managing_staff: boolean
          job_title: string | null
          last_name: string | null
          phone: string | null
          preferred_language: Database["public"]["Enums"]["app_language"]
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          auth_user_id?: string | null
          avatar_url?: string | null
          company_id: string
          created_at?: string
          display_name?: string | null
          email?: string | null
          employee_code?: string | null
          first_name: string
          hire_date?: string | null
          id?: string
          is_active?: boolean
          is_managing_staff?: boolean
          job_title?: string | null
          last_name?: string | null
          phone?: string | null
          preferred_language?: Database["public"]["Enums"]["app_language"]
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          auth_user_id?: string | null
          avatar_url?: string | null
          company_id?: string
          created_at?: string
          display_name?: string | null
          email?: string | null
          employee_code?: string | null
          first_name?: string
          hire_date?: string | null
          id?: string
          is_active?: boolean
          is_managing_staff?: boolean
          job_title?: string | null
          last_name?: string | null
          phone?: string | null
          preferred_language?: Database["public"]["Enums"]["app_language"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_profiles_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          branch_id: string | null
          created_at: string
          id: string
          role_id: string
          user_id: string
        }
        Insert: {
          branch_id?: string | null
          created_at?: string
          id?: string
          role_id: string
          user_id: string
        }
        Update: {
          branch_id?: string | null
          created_at?: string
          id?: string
          role_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_roles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_roles_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      work_schedules: {
        Row: {
          closes_at: string
          company_id: string
          created_at: string
          id: string
          is_closed: boolean
          opens_at: string
          updated_at: string
          weekday: number
        }
        Insert: {
          closes_at?: string
          company_id: string
          created_at?: string
          id?: string
          is_closed?: boolean
          opens_at?: string
          updated_at?: string
          weekday: number
        }
        Update: {
          closes_at?: string
          company_id?: string
          created_at?: string
          id?: string
          is_closed?: boolean
          opens_at?: string
          updated_at?: string
          weekday?: number
        }
        Relationships: [
          {
            foreignKeyName: "work_schedules_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      partner_balances: {
        Row: {
          balance: number | null
          company_id: string | null
          name: string | null
          partner_id: string | null
        }
        Insert: {
          balance?: never
          company_id?: string | null
          name?: string | null
          partner_id?: string | null
        }
        Update: {
          balance?: never
          company_id?: string | null
          name?: string | null
          partner_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "partners_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
      partner_ownership: {
        Row: {
          company_id: string | null
          name: string | null
          open_loans: number | null
          ownership_percentage: number | null
          partner_id: string | null
          total_contributions: number | null
        }
        Relationships: [
          {
            foreignKeyName: "partners_company_id_fkey"
            columns: ["company_id"]
            isOneToOne: false
            referencedRelation: "companies"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _assert_can_close_shift: {
        Args: { _shift_id: string }
        Returns: undefined
      }
      _attribute_shift_shortage: {
        Args: {
          _actor: string
          _mode: string
          _reason: string
          _s: Database["public"]["Tables"]["shifts"]["Row"]
          _short: number
          _staff_id: string
        }
        Returns: string
      }
      _cashback_accrue: {
        Args: {
          _actor: string
          _company: string
          _customer: string
          _order: string
          _order_number: string
          _spend: number
        }
        Returns: number
      }
      _charge_staff: {
        Args: {
          _amount: number
          _bearer: string
          _company: string
          _order_id: string
          _reason: string
          _shift_id: string
          _source: string
          _staff_id: string
        }
        Returns: number
      }
      _charge_waste: {
        Args: { _mv: string; _staff: string[] }
        Returns: number
      }
      _check_waste_bearer: {
        Args: { _bearer: string; _staff_id: string }
        Returns: undefined
      }
      _finalize_shift_close: {
        Args: {
          _actor: string
          _counted: number
          _mode: string
          _notes: string
          _retained: number
          _shift_id: string
          _source: string
          _staff_id: string
        }
        Returns: Json
      }
      _management_salary: {
        Args: { _company: string; _from: string; _pnl: Json; _to: string }
        Returns: {
          amount: number
          base_net_profit: number
          partner_id: string
          partner_name: string
          pct: number
          user_id: string
        }[]
      }
      _on_open_order_shift: {
        Args: { _o: Database["public"]["Tables"]["orders"]["Row"] }
        Returns: boolean
      }
      _order_line_to_waste: {
        Args: {
          _bearer: string
          _order_item_id: string
          _qty: number
          _reason: string
          _staff_id: string
        }
        Returns: number
      }
      _payout_calc: {
        Args: { _company: string; _from: string; _fund: number; _to: string }
        Returns: Json
      }
      _payroll_lines: {
        Args: { _company: string; _end: string; _start: string }
        Returns: {
          absence_deduction: number
          absent_days: number
          advances: number
          advances_due: number
          already_generated: boolean
          base_salary: number
          bonuses: number
          carried_forward: number
          deduction_days: number
          employee_name: string
          hire_date: string
          job_title: string
          net_pay: number
          penalties: number
          penalties_due: number
          prorated_salary: number
          shifts_count: number
          user_id: string
          worked_days: number
          worked_hours: number
        }[]
      }
      _post_shift_electronic: {
        Args: {
          _day: string
          _s: Database["public"]["Tables"]["shifts"]["Row"]
        }
        Returns: number
      }
      _prorated_salary: {
        Args: { _base: number; _end: string; _hire: string; _start: string }
        Returns: number
      }
      _range_pnl: {
        Args: { _company: string; _from: string; _to: string }
        Returns: Json
      }
      _shift_figures: {
        Args: { _s: Database["public"]["Tables"]["shifts"]["Row"] }
        Returns: Json
      }
      _wallet_post: {
        Args: {
          _actor: string
          _amount: number
          _company: string
          _customer: string
          _description: string
          _kind: string
          _order: string
        }
        Returns: number
      }
      add_staff_bonus: {
        Args: {
          _amount: number
          _bonus_date?: string
          _reason: string
          _staff_id: string
        }
        Returns: string
      }
      adjust_customer_wallet: {
        Args: { _amount: number; _customer_id: string; _reason: string }
        Returns: number
      }
      admin_update_employee: {
        Args: {
          _base_salary: number
          _display_name: string
          _employee_code: string
          _first_name: string
          _hire_date: string
          _job_title: string
          _last_name: string
          _phone: string
          _user_id: string
        }
        Returns: undefined
      }
      advance_outstanding: {
        Args: { _a: Database["public"]["Tables"]["employee_advances"]["Row"] }
        Returns: number
      }
      apply_stock_movement: {
        Args: {
          _branch_id: string
          _item_id: string
          _qty: number
          _reason?: string
          _reference_id?: string
          _reference_type?: string
          _type: Database["public"]["Enums"]["stock_movement_type"]
          _unit_cost?: number
        }
        Returns: string
      }
      apply_weighted_cost: {
        Args: {
          _branch_id: string
          _item_id: string
          _qty: number
          _unit_cost: number
        }
        Returns: number
      }
      approve_expense: { Args: { _expense_id: string }; Returns: string }
      assert_period_open: {
        Args: { _company_id: string; _date: string }
        Returns: undefined
      }
      attendance_deduction_days: {
        Args: {
          _company_id: string
          _end: string
          _start: string
          _user_id: string
        }
        Returns: number
      }
      auto_close_due_shifts: { Args: never; Returns: number }
      bar_low_stock: {
        Args: { _branch_id: string }
        Returns: {
          bar_min: number
          bar_qty: number
          item_id: string
          name: string
          product_ids: string[]
          unit: string
        }[]
      }
      begin_stock_override: {
        Args: { _branch_id: string; _items: Json; _reason?: string }
        Returns: string
      }
      bootstrap_current_user: {
        Args: { _first_name?: string; _last_name?: string }
        Returns: string
      }
      bulk_create_inventory_items: {
        Args: { _branch_id?: string; _items: Json }
        Returns: Json
      }
      business_date: {
        Args: { _company?: string; _ts: string }
        Returns: string
      }
      business_day_start: {
        Args: { _company?: string; _day: string }
        Returns: string
      }
      business_today: { Args: { _company?: string }; Returns: string }
      can_absorb_shortage: { Args: never; Returns: boolean }
      can_access_branch: { Args: { _branch_id: string }; Returns: boolean }
      can_refund_order: {
        Args: { _o: Database["public"]["Tables"]["orders"]["Row"] }
        Returns: boolean
      }
      cancel_advance: {
        Args: { _advance_id: string; _reason: string }
        Returns: string
      }
      cancel_partner_advance: {
        Args: { _advance_id: string; _reason: string }
        Returns: string
      }
      cancel_pos_order: {
        Args: {
          _bearer?: string
          _order_id: string
          _prepared?: boolean
          _reason: string
          _staff_id?: string
        }
        Returns: string
      }
      cancel_purchase: {
        Args: { _purchase_id: string; _reason: string }
        Returns: string
      }
      cash_balance: { Args: { _account_id: string }; Returns: number }
      cash_movements_summary: {
        Args: { _account_id?: string; _from: string; _to: string }
        Returns: Json
      }
      cashback_config: { Args: { _company: string }; Returns: Json }
      cashback_settings: { Args: never; Returns: Json }
      cashier_can_see_shift: { Args: { _shift_id: string }; Returns: boolean }
      check_order_stock: {
        Args: { _branch_id: string; _items: Json }
        Returns: undefined
      }
      clock_in: { Args: { _branch_id?: string }; Returns: string }
      clock_out: { Args: never; Returns: string }
      close_shift: {
        Args: { _closing_cash: number; _notes?: string; _shift_id: string }
        Returns: string
      }
      close_shift_handover: {
        Args: {
          _closing_cash: number
          _notes?: string
          _retained_float: number
          _shift_id: string
          _shortage_mode?: string
          _shortage_staff_id?: string
        }
        Returns: Json
      }
      company_financial_snapshot: {
        Args: { _company_id?: string }
        Returns: Json
      }
      company_tz: { Args: { _company?: string }; Returns: string }
      correct_expense_amount: {
        Args: { _expense_id: string; _new_amount: number; _reason: string }
        Returns: string
      }
      create_advance: {
        Args: {
          _advance_date?: string
          _amount: number
          _deduct_month?: string
          _reason?: string
          _user_id: string
        }
        Returns: string
      }
      create_expense_entry: {
        Args: {
          _amount: number
          _branch_id?: string
          _category_id?: string
          _description?: string
          _expense_date?: string
          _payment_method?: string
          _vendor?: string
        }
        Returns: string
      }
      create_inventory_item: {
        Args: {
          _branch_id?: string
          _cost_per_unit?: number
          _min_qty?: number
          _name: string
          _name_ar?: string
          _opening_qty?: number
          _sku?: string
          _unit?: string
        }
        Returns: string
      }
      create_partner_entry: {
        Args: {
          _email?: string
          _name: string
          _notes?: string
          _phone?: string
        }
        Returns: string
      }
      create_pos_order: {
        Args: {
          _branch_id: string
          _customer_id?: string
          _customer_name?: string
          _customer_phone?: string
          _discount_amount?: number
          _discount_reason?: string
          _items: Json
          _notes?: string
          _on_partner_tab?: boolean
          _order_type?: Database["public"]["Enums"]["order_type"]
          _partner_id?: string
          _payments: Json
          _voucher_code?: string
        }
        Returns: {
          out_id: string
          out_number: string
        }[]
      }
      create_purchase: {
        Args: {
          _branch_id: string
          _discount_amount?: number
          _invoice_number?: string
          _items: Json
          _notes?: string
          _paid_amount?: number
          _payment_method?: string
          _purchase_date?: string
          _receive?: boolean
          _supplier_id: string
          _tax_amount?: number
        }
        Returns: string
      }
      create_shift_expense: {
        Args: {
          _amount: number
          _category_id?: string
          _description?: string
          _shift_id: string
          _vendor?: string
        }
        Returns: string
      }
      create_soft_opening_order:
        | {
            Args: {
              _branch_id: string
              _items: Json
              _method_key?: string
              _notes?: string
              _tendered?: number
            }
            Returns: {
              out_id: string
              out_number: string
            }[]
          }
        | {
            Args: {
              _branch_id: string
              _discount_amount?: number
              _discount_reason?: string
              _items: Json
              _method_key?: string
              _notes?: string
              _tendered?: number
            }
            Returns: {
              out_id: string
              out_number: string
            }[]
          }
      current_company_id: { Args: never; Returns: string }
      current_partner_id: { Args: never; Returns: string }
      current_profile_id: { Args: never; Returns: string }
      customer_card: { Args: { _barcode: string }; Returns: Json }
      customer_cashback: { Args: { _customer_id: string }; Returns: Json }
      decide_stock_transfer: {
        Args: { _approve: boolean; _id: string; _reason?: string }
        Returns: undefined
      }
      default_cash_account: {
        Args: { _company_id: string; _method?: string }
        Returns: string
      }
      delete_backup_entry: { Args: { p_id: string }; Returns: boolean }
      delete_category_hard: { Args: { _category_id: string }; Returns: Json }
      delete_inventory_item: {
        Args: { _item_id: string; _unlink_recipes?: boolean }
        Returns: Json
      }
      delete_modifier_group: { Args: { _group_id: string }; Returns: Json }
      delete_modifier_option: { Args: { _option_id: string }; Returns: Json }
      delete_partner_safe: { Args: { _partner_id: string }; Returns: undefined }
      delete_product_hard: { Args: { _product_id: string }; Returns: Json }
      delete_role: {
        Args: { _reassign_role_id?: string; _role_id: string }
        Returns: string
      }
      delete_user_by_admin: {
        Args: { p_target_user_id: string }
        Returns: string
      }
      delete_user_document: { Args: { _doc_id: string }; Returns: string }
      development_fund_balance: { Args: never; Returns: number }
      edit_stock_movement: {
        Args: {
          _movement_id: string
          _quantity: number
          _reason?: string
          _unit_cost?: number
        }
        Returns: Json
      }
      emergency_stock_transfer: {
        Args: { _branch_id: string; _items: Json; _notes?: string }
        Returns: string
      }
      execute_operational_reset:
        | { Args: { p_confirm?: string }; Returns: Json }
        | { Args: { p_confirm?: string; p_targets?: string[] }; Returns: Json }
      execute_payout: {
        Args: {
          _development_fund?: number
          _from: string
          _notes?: string
          _to: string
        }
        Returns: string
      }
      execute_salary_payment: {
        Args: { _account_id?: string; _method?: string; _salary_id: string }
        Returns: string
      }
      expenses_period_summary: {
        Args: { _from: string; _to: string }
        Returns: Json
      }
      financial_self_sustainability: { Args: never; Returns: Json }
      force_close_stuck_shift: {
        Args: { _branch_id: string; _reason?: string }
        Returns: Json
      }
      get_my_partner_profit_summary: { Args: never; Returns: Json }
      go_live_reset: {
        Args: { _confirm: string; _reason: string; _reset_stock?: boolean }
        Returns: Json
      }
      has_permission: { Args: { _key: string }; Returns: boolean }
      hr_add_penalty: {
        Args: {
          _amount: number
          _order_id?: string
          _reason: string
          _staff_id: string
        }
        Returns: string
      }
      hr_manager_percent_pay: {
        Args: { _period_end: string; _period_start: string }
        Returns: {
          amount: number
          base_net_profit: number
          employee_name: string
          paid_at: string
          partner_id: string
          pct: number
          recorded_amount: number
          salary_id: string
          user_id: string
        }[]
      }
      hr_payroll_preview: {
        Args: { _period_end: string; _period_start: string }
        Returns: {
          absence_deduction: number
          absent_days: number
          advances: number
          advances_due: number
          already_generated: boolean
          base_salary: number
          bonuses: number
          carried_forward: number
          deduction_days: number
          employee_name: string
          hire_date: string
          job_title: string
          net_pay: number
          penalties: number
          penalties_due: number
          prorated_salary: number
          shifts_count: number
          user_id: string
          worked_days: number
          worked_hours: number
        }[]
      }
      inventory_cogs_report: {
        Args: { _branch_id: string; _from: string; _to: string }
        Returns: Json
      }
      inventory_item_usage: { Args: { _item_id: string }; Returns: Json }
      is_can_eligible_product: {
        Args: { _category_id: string; _name: string }
        Returns: boolean
      }
      is_cashier_only: { Args: never; Returns: boolean }
      is_root_admin: { Args: never; Returns: boolean }
      is_super_admin: { Args: never; Returns: boolean }
      last_retained_float: { Args: { _branch_id: string }; Returns: number }
      line_cogs: {
        Args: { _oi: Database["public"]["Tables"]["order_items"]["Row"] }
        Returns: number
      }
      line_raw_cost: {
        Args: { _oi: Database["public"]["Tables"]["order_items"]["Row"] }
        Returns: number
      }
      link_partner_account: {
        Args: { _email: string; _partner_id: string }
        Returns: string
      }
      liquidate_partner: {
        Args: {
          _cash_account_id?: string
          _notes?: string
          _partner_id: string
          _settlement_method: string
        }
        Returns: string
      }
      log_audit: {
        Args: {
          _action: string
          _branch_id?: string
          _entity_id?: string
          _entity_type?: string
          _module: string
          _new_values?: Json
          _old_values?: Json
          _reason?: string
        }
        Returns: string
      }
      loyalty_config: { Args: { _company: string }; Returns: Json }
      loyalty_settings: { Args: never; Returns: Json }
      mark_order_delivered: { Args: { _order_id: string }; Returns: string }
      monthly_operating_costs: {
        Args: { _from: string; _to: string }
        Returns: Json
      }
      my_owner_statement: { Args: never; Returns: Json }
      my_partner_dashboard: {
        Args: { _from: string; _to: string }
        Returns: Json
      }
      offer_candidates: {
        Args: { _from?: string; _to?: string }
        Returns: {
          base_price: number
          image_url: string
          margin: number
          name: string
          name_ar: string
          product_id: string
          qty: number
          revenue: number
          safe_floor: number
          unit_cost: number
        }[]
      }
      offer_price_preview: {
        Args: { _payload: Json }
        Returns: {
          base_total: number
          live_cost: number
          normal_margin: number
          normal_profit: number
          safe_floor: number
        }[]
      }
      offers_enabled: { Args: { _company_id?: string }; Returns: boolean }
      offers_performance: {
        Args: { _from?: string; _to?: string }
        Returns: {
          cogs: number
          discount_given: number
          margin_pct: number
          net_profit: number
          offer_id: string
          offer_price: number
          offer_type: string
          revenue: number
          times_sold: number
          title: string
        }[]
      }
      open_shift: {
        Args: { _branch_id: string; _opening_cash?: number }
        Returns: string
      }
      open_shift_with_roster: {
        Args: {
          _branch_id: string
          _opening_cash: number
          _staff_ids: string[]
        }
        Returns: string
      }
      operating_reserve_settings: { Args: never; Returns: Json }
      order_item_unit_cogs: {
        Args: { _order_item_id: string }
        Returns: number
      }
      orders_period_summary:
        | {
            Args: {
              _branch_id: string
              _from: string
              _order_type?: string
              _pay_method?: string
              _search?: string
              _shift_id?: string
              _status?: string
              _to: string
            }
            Returns: Json
          }
        | {
            Args: {
              _branch_id?: string
              _from: string
              _status?: string
              _to: string
            }
            Returns: Json
          }
      partner_balance: { Args: { _partner_id: string }; Returns: number }
      pay_purchase: {
        Args: {
          _amount: number
          _notes?: string
          _paid_at?: string
          _purchase_id: string
          _source?: string
        }
        Returns: string
      }
      pending_shift_shortages: {
        Args: never
        Returns: {
          business_date: string
          cashier: string
          closed_at: string
          opened_at: string
          shift_id: string
          shortage: number
        }[]
      }
      pay_salary: {
        Args: { _account_id?: string; _method?: string; _salary_id: string }
        Returns: string
      }
      payout_history: { Args: { _limit?: number }; Returns: Json }
      payout_partner_combined: {
        Args: {
          _distribution_id: string
          _method?: string
          _partner_id: string
          _salary_payment_id: string
        }
        Returns: undefined
      }
      payout_partner_dividend: {
        Args: {
          _account_id?: string
          _distribution_id: string
          _method?: string
          _partner_id: string
        }
        Returns: string
      }
      payout_preview: {
        Args: { _development_fund?: number; _from: string; _to: string }
        Returns: Json
      }
      penalty_outstanding: {
        Args: { _p: Database["public"]["Tables"]["staff_penalties"]["Row"] }
        Returns: number
      }
      pos_partners: {
        Args: never
        Returns: {
          customer_id: string
          id: string
          name: string
        }[]
      }
      post_cash_txn: {
        Args: {
          _account_id: string
          _amount: number
          _category: string
          _company_id: string
          _description?: string
          _direction: string
          _enforce_balance?: boolean
          _method?: string
          _reference_id?: string
          _reference_type?: string
          _transfer_group?: string
          _txn_date?: string
        }
        Returns: string
      }
      product_costs: {
        Args: never
        Returns: {
          cost: number
          product_id: string
        }[]
      }
      product_demand: {
        Args: { _from: string; _to: string }
        Returns: {
          base_price: number
          category: string
          cost: number
          image_url: string
          last_sold_at: string
          margin: number
          name: string
          name_ar: string
          orders_count: number
          product_id: string
          qty: number
          revenue: number
          unit_cost: number
        }[]
      }
      public_menu: { Args: { _branch_id: string }; Returns: Json }
      purchase_cost_warnings: { Args: { _items: Json }; Returns: Json }
      purchases_period_summary: {
        Args: {
          _branch_id?: string
          _from: string
          _status?: string
          _to: string
        }
        Returns: Json
      }
      range_pnl: { Args: { _from: string; _to: string }; Returns: Json }
      reassign_shift_shortage: {
        Args: {
          _mode: string
          _reason?: string
          _shift_id: string
          _staff_id?: string
        }
        Returns: Json
      }
      recost_sales_now: { Args: never; Returns: Json }
      recalc_order_totals: { Args: { _order_id: string }; Returns: undefined }
      receive_purchase: { Args: { _purchase_id: string }; Returns: string }
      recompute_capital_equity: {
        Args: { _company_id: string }
        Returns: undefined
      }
      preview_partner_contribution: {
        Args: {
          _amount: number
          _contribution_date?: string
          _kind?: string
          _partner_id: string
        }
        Returns: Json
      }
      record_partner_contribution: {
        Args: {
          _amount: number
          _contribution_date?: string
          _kind: string
          _notes?: string
          _partner_id: string
          _payment_method?: string
          _reference?: string
        }
        Returns: string
      }
      record_capital_contribution: {
        Args: {
          _amount: number
          _contribution_date?: string
          _notes?: string
          _partner_id: string
          _payment_method?: string
          _reference?: string
        }
        Returns: string
      }
      record_manager_percent_salary: {
        Args: {
          _partner_id: string
          _period_end: string
          _period_start: string
        }
        Returns: string
      }
      record_partner_advance: {
        Args: {
          _advance_date?: string
          _amount: number
          _method?: string
          _partner_id: string
          _reason?: string
        }
        Returns: string
      }
      record_purchase_payment: {
        Args: {
          _amount: number
          _method?: string
          _notes?: string
          _paid_at?: string
          _purchase_id: string
        }
        Returns: string
      }
      record_stock_movement: {
        Args: {
          _branch_id: string
          _item_id: string
          _qty: number
          _reason?: string
          _type: Database["public"]["Enums"]["stock_movement_type"]
          _unit_cost?: number
        }
        Returns: string
      }
      record_waste: {
        Args: {
          _bearer: string
          _branch_id: string
          _item_id: string
          _qty: number
          _reason: string
          _staff_id?: string
        }
        Returns: Json
      }
      refund_order: {
        Args: {
          _amount: number
          _method_key?: string
          _order_id: string
          _reason: string
        }
        Returns: string
      }
      refund_order_full: {
        Args: {
          _fault?: string
          _method_key?: string
          _order_id: string
          _reason: string
          _staff_id?: string
        }
        Returns: Json
      }
      refund_order_items: {
        Args: {
          _items: Json
          _method_key?: string
          _order_id: string
          _reason?: string
        }
        Returns: Json
      }
      refund_order_items_attributed: {
        Args: {
          _fault: string
          _items: Json
          _method_key: string
          _order_id: string
          _reason: string
          _staff_id?: string
        }
        Returns: Json
      }
      refund_shift_for: {
        Args: {
          _method_key: string
          _o: Database["public"]["Tables"]["orders"]["Row"]
        }
        Returns: string
      }
      refund_target_shift: {
        Args: { _branch_id: string; _method_key: string }
        Returns: string
      }
      remove_user_by_admin: {
        Args: { p_target_user_id: string }
        Returns: Json
      }
      request_partner_withdrawal: {
        Args: {
          _amount: number
          _method?: string
          _notes?: string
          _partner_id?: string
        }
        Returns: string
      }
      request_stock_transfer: {
        Args: { _branch_id: string; _items: Json; _notes?: string }
        Returns: string
      }
      reset_operational_data: { Args: { p_confirm: string }; Returns: Json }
      reset_test_shift: {
        Args: { _reason: string; _shift_id: string }
        Returns: Json
      }
      restore_backup_snapshot: {
        Args: { p_confirm?: string; p_payload: Json }
        Returns: Json
      }
      return_line_stock: {
        Args: { _order_item_id: string }
        Returns: undefined
      }
      return_purchase_items: {
        Args: {
          _items: Json
          _purchase_id: string
          _reason: string
          _refund_mode?: string
          _return_date?: string
        }
        Returns: string
      }
      reverse_partner_dividend_payout: {
        Args: { _payout_id: string; _reason: string }
        Returns: string
      }
      reverse_payout: {
        Args: { _distribution_id: string; _reason: string }
        Returns: string
      }
      review_expense: {
        Args: { _decision: string; _expense_id: string }
        Returns: string
      }
      review_partner_withdrawal: {
        Args: {
          _account_id?: string
          _approve: boolean
          _note?: string
          _request_id: string
        }
        Returns: string
      }
      role_usage: {
        Args: { _role_id: string }
        Returns: {
          display_name: string
          email: string
          user_id: string
        }[]
      }
      run_payroll: {
        Args: { _period_end: string; _period_start: string }
        Returns: number
      }
      salary_line_cost: {
        Args: { _s: Database["public"]["Tables"]["salary_payments"]["Row"] }
        Returns: number
      }
      sales_period_summary: {
        Args: { _branch_id?: string; _from: string; _to: string }
        Returns: Json
      }
      save_product_offer: { Args: { _payload: Json }; Returns: string }
      save_product_recipe: {
        Args: { _lines: Json; _product_id: string }
        Returns: Json
      }
      save_product_studio: { Args: { _payload: Json }; Returns: Json }
      save_recipe_matrix: {
        Args: { _lines: Json; _product_id: string }
        Returns: undefined
      }
      save_supplier: {
        Args: {
          _address?: string
          _contact_person?: string
          _email?: string
          _id?: string
          _is_active?: boolean
          _name?: string
          _notes?: string
          _payment_terms?: string
          _phone?: string
        }
        Returns: string
      }
      set_bar_min_qty: {
        Args: { _item_id: string; _qty: number }
        Returns: undefined
      }
      set_cashback_settings: {
        Args: {
          _enabled: boolean
          _reward_amount: number
          _target_amount: number
        }
        Returns: Json
      }
      set_employee_hire_date: {
        Args: { _hire_date: string; _user_id: string }
        Returns: undefined
      }
      set_item_waste_pct: {
        Args: { _item_id: string; _waste_pct: number }
        Returns: undefined
      }
      set_manager_compensation: {
        Args: {
          _basis: string
          _fixed: number
          _mode: string
          _percent: number
          _profile_id: string
        }
        Returns: undefined
      }
      set_nav_override: {
        Args: { _path: string; _profile_id: string; _visible: boolean }
        Returns: undefined
      }
      set_offer_active: {
        Args: { _active: boolean; _offer_id: string; _reason?: string }
        Returns: boolean
      }
      set_offers_enabled: { Args: { _enabled: boolean }; Returns: boolean }
      set_partner_dividends_paused: {
        Args: { _partner_id: string; _paused: boolean }
        Returns: undefined
      }
      set_partner_managing: {
        Args: {
          _base_salary?: number
          _hire_date?: string
          _job_title?: string
          _on: boolean
          _partner_id: string
        }
        Returns: string
      }
      set_partner_salary_type: {
        Args: { _partner_id: string; _pct: number; _type: string }
        Returns: undefined
      }
      set_partner_tier: {
        Args: { _partner_id: string; _tier: string }
        Returns: undefined
      }
      set_product_availability: {
        Args: { _available: boolean; _product_id: string }
        Returns: undefined
      }
      set_purchase_meta: {
        Args: {
          _attachment_path?: string
          _purchase_id: string
          _terms?: string
        }
        Returns: undefined
      }
      set_role_permission: {
        Args: { _enabled: boolean; _permission_key: string; _role_id: string }
        Returns: undefined
      }
      set_shift_roster: {
        Args: { _shift_id: string; _staff_ids: string[] }
        Returns: undefined
      }
      set_super_admin_managing: {
        Args: {
          _base_salary?: number
          _hire_date?: string
          _job_title?: string
          _on: boolean
        }
        Returns: string
      }
      set_user_roles: {
        Args: { _role_ids: string[]; _user_id: string }
        Returns: string
      }
      set_user_super_admin: {
        Args: { _on: boolean; _profile_id: string }
        Returns: undefined
      }
      settle_partner_negative_balance: {
        Args: { _amount?: number; _mode: string; _partner_id: string }
        Returns: Json
      }
      shift_deadline_info: { Args: never; Returns: Json }
      shift_expected_cash: { Args: { _shift_id: string }; Returns: Json }
      shift_expense_total: { Args: { _shift_id: string }; Returns: number }
      shift_financials: { Args: { _shift_ids: string[] }; Returns: Json }
      shift_staff_candidates: {
        Args: never
        Returns: {
          id: string
          job_title: string
          name: string
        }[]
      }
      spend_development_fund: {
        Args: { _account_id?: string; _amount: number; _description: string }
        Returns: string
      }
      stocktake_preview: {
        Args: { _branch_id: string; _scope: string }
        Returns: {
          allowance: number
          consumption: number
          expected: number
          item_id: string
          location: string
          name: string
          other: number
          purchases: number
          since: string
          start_qty: number
          transfers_in: number
          transfers_out: number
          unit: string
          unit_cost: number
        }[]
      }
      submit_stocktake: {
        Args: {
          _branch_id: string
          _counts: Json
          _notes?: string
          _scope: string
        }
        Returns: string
      }
      submit_stocktake_settled: {
        Args: {
          _branch_id: string
          _counts: Json
          _notes?: string
          _scope: string
          _settlement?: string
          _shift_id?: string
          _staff_id?: string
        }
        Returns: string
      }
      supplier_payables: {
        Args: never
        Returns: {
          due: number
          open_count: number
          paid: number
          supplier_id: string
          supplier_name: string
          total: number
        }[]
      }
      tender_key: { Args: { _method: string }; Returns: string }
      transfer_cash: {
        Args: {
          _amount: number
          _description?: string
          _from_account: string
          _to_account: string
          _txn_date?: string
        }
        Returns: string
      }
      transfer_stock: {
        Args: {
          _from_branch: string
          _item_id: string
          _qty: number
          _reason?: string
          _to_branch: string
        }
        Returns: undefined
      }
      treasury_entry: {
        Args: {
          _account_id: string
          _amount: number
          _category?: string
          _description: string
          _direction: string
          _method: string
          _txn_date: string
        }
        Returns: string
      }
      treasury_overview: { Args: never; Returns: Json }
      update_customer_details: {
        Args: { _customer_id: string; _name: string; _phone: string }
        Returns: undefined
      }
      update_employee_advance: {
        Args: {
          _advance_id: string
          _amount: number
          _deduct_month: string
          _reason?: string
        }
        Returns: string
      }
      update_employee_profile: {
        Args: {
          _base_salary: number
          _hire_date: string
          _job_title: string
          _name: string
          _user_id: string
        }
        Returns: undefined
      }
      update_partner_details: {
        Args: {
          _name: string
          _partner_id: string
          _profit_share_percentage?: number
        }
        Returns: undefined
      }
      update_shift_closing_cash: {
        Args: {
          _closing_cash: number
          _reason: string
          _shift_id: string
          _shortage_mode?: string
          _shortage_staff_id?: string
        }
        Returns: Json
      }
      upsert_attendance: {
        Args: {
          _branch_id?: string
          _check_in?: string
          _check_out?: string
          _notes?: string
          _permission_hours?: number
          _status?: string
          _user_id: string
          _work_date: string
        }
        Returns: string
      }
      upsert_customer: {
        Args: { _customer_id?: string; _name: string; _phone: string }
        Returns: string
      }
      upsert_employee_salary: {
        Args: {
          _base_salary: number
          _effective_from?: string
          _notes?: string
          _user_id: string
        }
        Returns: string
      }
      void_order_item: {
        Args: {
          _bearer?: string
          _order_item_id: string
          _prepared?: boolean
          _reason: string
          _staff_id?: string
        }
        Returns: string
      }
      waive_staff_penalty: {
        Args: { _penalty_id: string; _reason: string }
        Returns: string
      }
      waste_factor: { Args: { _item_id: string }; Returns: number }
      waste_share_staff: { Args: { _company: string }; Returns: string[] }
      wipe_all_raw_materials: { Args: never; Returns: Json }
      work_day_close_at: {
        Args: { _company_id: string; _reference: string }
        Returns: string
      }
    }
    Enums: {
      app_language: "ar" | "en"
      ledger_txn_type:
        | "profit_distribution"
        | "withdrawal"
        | "capital_contribution"
        | "adjustment"
      order_item_status: "active" | "voided"
      order_status:
        | "open"
        | "completed"
        | "cancelled"
        | "refunded"
        | "pending"
        | "partially_refunded"
      order_type: "dine_in" | "takeaway" | "delivery"
      partner_status: "active" | "inactive" | "exited"
      period_status: "open" | "closed"
      period_type: "monthly" | "quarterly" | "yearly" | "custom"
      purchase_status: "draft" | "received" | "cancelled"
      record_status: "active" | "cancelled" | "voided" | "reversed"
      shift_status: "open" | "closed"
      stock_movement_type:
        | "purchase"
        | "adjustment"
        | "waste"
        | "transfer_in"
        | "transfer_out"
        | "sale_consumption"
        | "sale_return"
        | "stocktake"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_language: ["ar", "en"],
      ledger_txn_type: [
        "profit_distribution",
        "withdrawal",
        "capital_contribution",
        "adjustment",
      ],
      order_item_status: ["active", "voided"],
      order_status: [
        "open",
        "completed",
        "cancelled",
        "refunded",
        "pending",
        "partially_refunded",
      ],
      order_type: ["dine_in", "takeaway", "delivery"],
      partner_status: ["active", "inactive", "exited"],
      period_status: ["open", "closed"],
      period_type: ["monthly", "quarterly", "yearly", "custom"],
      purchase_status: ["draft", "received", "cancelled"],
      record_status: ["active", "cancelled", "voided", "reversed"],
      shift_status: ["open", "closed"],
      stock_movement_type: [
        "purchase",
        "adjustment",
        "waste",
        "transfer_in",
        "transfer_out",
        "sale_consumption",
        "sale_return",
        "stocktake",
      ],
    },
  },
} as const
