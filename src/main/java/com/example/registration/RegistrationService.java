package com.example.registration;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import javax.sql.DataSource;

public class RegistrationService {

    private static final String UNIQUE_VIOLATION = "23505";

    private final DataSource dataSource;

    public RegistrationService(DataSource dataSource) {
        this.dataSource = dataSource;
        try (Connection c = dataSource.getConnection(); Statement s = c.createStatement()) {
            s.execute(Schema.DDL);
        } catch (SQLException e) {
            throw new IllegalStateException("Could not create schema", e);
        }
    }

    /** Returns true if a new row was created, false if the email already exists. */
    public boolean register(String email) {
        try (Connection c = dataSource.getConnection();
                PreparedStatement ps = c.prepareStatement("INSERT INTO users (email) VALUES (?)")) {
            ps.setString(1, email);
            ps.executeUpdate();
            return true;
        } catch (SQLException e) {
            if (UNIQUE_VIOLATION.equals(e.getSQLState())) {
                return false;
            }
            throw new IllegalStateException("Registration failed", e);
        }
    }

    public boolean isRegistered(String email) {
        try (Connection c = dataSource.getConnection();
                PreparedStatement ps = c.prepareStatement("SELECT 1 FROM users WHERE email = ?")) {
            ps.setString(1, email);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        } catch (SQLException e) {
            throw new IllegalStateException("Lookup failed", e);
        }
    }

    public int count() {
        try (Connection c = dataSource.getConnection();
                Statement s = c.createStatement();
                ResultSet rs = s.executeQuery("SELECT count(*) FROM users")) {
            rs.next();
            return rs.getInt(1);
        } catch (SQLException e) {
            throw new IllegalStateException("Count failed", e);
        }
    }
}
